defmodule Jeff.VirtualBus do
  @moduledoc """
  Creates a pair of linked virtual serial ports using `socat`.

  Requires `socat` to be installed:

      brew install socat

  ## Usage

      {:ok, bus} = Jeff.VirtualBus.create()
      # bus.acu_port => "/dev/ttys002"  (give to ACU)
      # bus.pd_port  => "/dev/ttys003"  (give to VirtualPD)

      Jeff.VirtualBus.destroy(bus.socat_port)
  """

  @doc """
  Spawn `socat` and return the two linked PTY device paths.

  Returns `{:ok, %{acu_port: path, pd_port: path, socat_port: port}}` on
  success, or `{:error, reason}` if `socat` could not be started or the
  PTY paths could not be parsed within 2 seconds.
  """
  @spec create() :: {:ok, map()} | {:error, term()}
  def create do
    socat_port =
      Port.open({:spawn, "socat -d -d pty,raw,echo=0 pty,raw,echo=0"}, [
        :binary,
        :stderr_to_stdout,
        :exit_status
      ])

    collect_pty_paths(socat_port, [], System.monotonic_time(:millisecond))
  end

  @doc "Kill the socat process and clean up the virtual serial pair."
  @spec destroy(port()) :: true
  def destroy(socat_port) when is_port(socat_port) do
    Port.close(socat_port)
  end

  defp collect_pty_paths(socat_port, paths, started_at) do
    now = System.monotonic_time(:millisecond)

    if now - started_at > 2000 do
      Port.close(socat_port)
      {:error, :timeout}
    else
      receive do
        {^socat_port, {:data, data}} ->
          new_paths = parse_pty_paths(data, paths)

          if length(new_paths) >= 2 do
            [acu_port, pd_port] = Enum.take(new_paths, 2)
            {:ok, %{acu_port: acu_port, pd_port: pd_port, socat_port: socat_port}}
          else
            collect_pty_paths(socat_port, new_paths, started_at)
          end

        {^socat_port, {:exit_status, code}} ->
          {:error, {:socat_exited, code}}
      after
        100 ->
          collect_pty_paths(socat_port, paths, started_at)
      end
    end
  end

  defp parse_pty_paths(data, existing) do
    Regex.scan(~r/PTY is (\/dev\/\S+)/, data)
    |> Enum.map(fn [_, path] -> String.trim(path) end)
    |> then(&(existing ++ &1))
    |> Enum.uniq()
  end
end
