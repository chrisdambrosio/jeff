defmodule Jeff.VirtualPD do
  @moduledoc """
  A virtual Peripheral Device (PD) for testing and demonstration.

  Implements the PD side of the OSDP protocol, allowing the Jeff ACU to
  communicate with a software-simulated device over a virtual serial port
  (e.g. one created by `Jeff.VirtualBus`).

  ## Usage

      {:ok, bus} = Jeff.VirtualBus.create()
      {:ok, pd} = Jeff.VirtualPD.start_link(bus.pd_port,
        address: 0x7F,
        controlling_process: self()
      )

      # Inject a card swipe that will be delivered on the next POLL
      Jeff.VirtualPD.inject_card_read(pd, <<0xDE, 0xAD, 0xBE, 0xEF>>)

  ## Events

  The `controlling_process` receives:

    * `%Jeff.VirtualPD.BusEvent{}` — for every OSDP packet sent or received
    * `%Jeff.VirtualPD.StateEvent{}` — when LED, buzzer, or output state changes
  """

  use GenServer

  import Bitwise

  require Logger

  alias Circuits.UART
  alias Jeff.{ControlInfo, ErrorChecks, Message}

  @som 0x53

  # Command codes
  @poll 0x60
  @id 0x61
  @cap 0x62
  @lstat 0x64
  @istat 0x65
  @ostat 0x66
  @led 0x69
  @buz 0x6A
  @out 0x68
  @chlng 0x76

  # Reply codes
  @ack 0x40
  @nak 0x41
  @pdid 0x45
  @pdcap 0x46
  @lstatr 0x48
  @istatr 0x49
  @ostatr 0x4A
  @raw 0x50
  @keypad 0x53

  defstruct [
    :address,
    :uart,
    :port,
    :controlling_process,
    check_scheme: :crc,
    leds: %{},
    buzzer: nil,
    outputs: %{},
    inputs: %{0 => :inactive, 1 => :inactive},
    pending_events: :queue.new()
  ]

  defmodule BusEvent do
    @moduledoc "Emitted for every OSDP packet received from or sent to the ACU."
    defstruct [:direction, :name, :address, :bytes]
  end

  defmodule StateEvent do
    @moduledoc "Emitted when PD state changes (LED, buzzer, output)."
    defstruct [:address, :type, :led, :on_color, :off_color, :tone, :on_time]
  end

  @doc "Start a VirtualPD listening on the given serial port."
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(port, opts \\ []) do
    GenServer.start_link(__MODULE__, {port, opts})
  end

  @doc "Queue a card read event to be delivered on the next POLL."
  @spec inject_card_read(GenServer.server(), binary()) :: :ok
  def inject_card_read(pid, data) do
    GenServer.cast(pid, {:inject, {:card_read, data}})
  end

  @doc "Queue a keypress event to be delivered on the next POLL."
  @spec inject_keypress(GenServer.server(), binary()) :: :ok
  def inject_keypress(pid, keys) do
    GenServer.cast(pid, {:inject, {:keypress, keys}})
  end

  @doc "Update the simulated state of an input point."
  @spec set_input(GenServer.server(), non_neg_integer(), :active | :inactive) :: :ok
  def set_input(pid, id, status) when status in [:active, :inactive] do
    GenServer.cast(pid, {:set_input, id, status})
  end

  # GenServer callbacks

  @impl GenServer
  def init({port, opts}) do
    address = Keyword.get(opts, :address, 0x7F)
    check_scheme = Keyword.get(opts, :check_scheme, :crc)
    controlling_process = Keyword.get(opts, :controlling_process, self())

    {:ok, uart} = UART.start_link()

    uart_opts = [
      active: true,
      speed: 9600,
      framing: Jeff.Framing
    ]

    case UART.open(uart, port, uart_opts) do
      :ok ->
        state = %__MODULE__{
          address: address,
          uart: uart,
          port: port,
          check_scheme: check_scheme,
          controlling_process: controlling_process
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast({:inject, event}, state) do
    {:noreply, %{state | pending_events: :queue.in(event, state.pending_events)}}
  end

  def handle_cast({:set_input, id, status}, state) do
    {:noreply, %{state | inputs: Map.put(state.inputs, id, status)}}
  end

  @impl GenServer
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    message = Message.decode(data)

    cmd_name = Jeff.Command.name(message.code) || :UNKNOWN

    notify(state.controlling_process, %BusEvent{
      direction: :rx,
      name: cmd_name,
      address: message.address,
      bytes: data
    })

    {reply_code, reply_data, state} = handle_command(message, state)

    # Use the check scheme from the incoming command so it always matches
    check_scheme = message.check_scheme || state.check_scheme

    reply_bytes =
      build_reply(state.address, message.sequence, check_scheme, reply_code, reply_data)

    reply_name = Jeff.Reply.name(reply_code) || :UNKNOWN

    notify(state.controlling_process, %BusEvent{
      direction: :tx,
      name: reply_name,
      address: state.address,
      bytes: reply_bytes
    })

    # Prepend driver byte as ACU framing expects it
    UART.write(state.uart, <<0xFF>> <> reply_bytes)

    {:noreply, state}
  end

  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.error("VirtualPD UART error: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Command dispatch

  defp handle_command(%{code: @poll}, state) do
    case :queue.out(state.pending_events) do
      {{:value, {:card_read, data}}, queue} ->
        bit_count = byte_size(data) * 8
        # reader_number(1), format(1 = raw), bit_count(2 LE), data
        raw_data = <<0x00, 0x01, bit_count::size(16)-little>> <> data
        {@raw, raw_data, %{state | pending_events: queue}}

      {{:value, {:keypress, keys}}, queue} ->
        # reader_number(1), bit_count(1), data
        keypad_data = <<0x00, byte_size(keys)>> <> keys
        {@keypad, keypad_data, %{state | pending_events: queue}}

      {:empty, _} ->
        {@ack, <<>>, state}
    end
  end

  defp handle_command(%{code: @id}, state) do
    # vendor(3), model(1), version(1), serial(4 LE), fw_major, fw_minor, fw_build
    data = <<0x00, 0x11, 0x22, 0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 1, 0, 0>>
    {@pdid, data, state}
  end

  defp handle_command(%{code: @cap}, state) do
    data =
      # contact status monitoring: unsupervised, 2 inputs
      <<1, 1, 2,
        # output control: direct, 2 outputs
        2, 1, 2,
        # card data format: raw bits
        3, 1, 0,
        # LED: timed bi-color, 1 LED
        4, 3, 1,
        # audible: timed
        5, 2, 0,
        # check character support: CRC
        8, 1, 0>>

    {@pdcap, data, state}
  end

  defp handle_command(%{code: @lstat}, state) do
    # tamper=0 (normal), power=0 (normal)
    {@lstatr, <<0x00, 0x00>>, state}
  end

  defp handle_command(%{code: @istat}, state) do
    data =
      state.inputs
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {_, s} -> if s == :active, do: 1, else: 0 end)
      |> :binary.list_to_bin()

    {@istatr, data, state}
  end

  defp handle_command(%{code: @ostat}, state) do
    data =
      state.outputs
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {_, s} -> if s == :active, do: 1, else: 0 end)
      |> :binary.list_to_bin()

    {@ostatr, data, state}
  end

  defp handle_command(%{code: @led, data: data}, state) do
    <<_reader, led_id, _temp_mode, _tmp_on, _tmp_off, _tmp_on_col, _tmp_off_col,
      _tmp_timer::16-little, _perm_mode, _perm_on, _perm_off, perm_on_color,
      perm_off_color>> = data

    on_color = color_name(perm_on_color)
    off_color = color_name(perm_off_color)
    leds = Map.put(state.leds, led_id, %{on_color: on_color, off_color: off_color})

    notify(state.controlling_process, %StateEvent{
      address: state.address,
      type: :led,
      led: led_id,
      on_color: on_color,
      off_color: off_color
    })

    {@ack, <<>>, %{state | leds: leds}}
  end

  defp handle_command(%{code: @buz, data: data}, state) do
    <<_reader, tone, on_time, _off_time, _count>> = data
    buzzer = %{tone: tone, on_time: on_time}

    notify(state.controlling_process, %StateEvent{
      address: state.address,
      type: :buzzer,
      tone: tone,
      on_time: on_time
    })

    {@ack, <<>>, %{state | buzzer: buzzer}}
  end

  defp handle_command(%{code: @out, data: data}, state) do
    <<output_id, code, _timer::16-little>> = data
    status = if code in [0x02, 0x04, 0x05], do: :active, else: :inactive
    {@ack, <<>>, %{state | outputs: Map.put(state.outputs, output_id, status)}}
  end

  defp handle_command(%{code: @chlng}, state) do
    # Security not supported in virtual mode
    {@nak, <<0x06>>, state}
  end

  defp handle_command(_unknown, state) do
    {@nak, <<0x00>>, state}
  end

  # Reply packet assembly

  defp build_reply(address, sequence, check_scheme, reply_code, reply_data) do
    reply_address = address ||| 0x80
    ctrl = ControlInfo.encode(sequence, check_scheme, false)
    check_size = if check_scheme == :crc, do: 2, else: 1
    total_length = 6 + byte_size(reply_data) + check_size

    header = <<@som, reply_address, total_length::size(16)-little, ctrl, reply_code>>
    packet = header <> reply_data

    case check_scheme do
      :crc ->
        check = ErrorChecks.crc(packet)
        packet <> <<check::size(16)-little>>

      :checksum ->
        check = ErrorChecks.checksum(packet)
        packet <> <<check>>
    end
  end

  defp color_name(0), do: :black
  defp color_name(1), do: :red
  defp color_name(2), do: :green
  defp color_name(3), do: :amber
  defp color_name(4), do: :blue
  defp color_name(5), do: :magenta
  defp color_name(6), do: :cyan
  defp color_name(7), do: :white
  defp color_name(_), do: :unknown

  defp notify(nil, _event), do: :ok
  defp notify(pid, event), do: send(pid, event)
end
