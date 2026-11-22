defmodule Jeff.VirtualBusTest do
  use ExUnit.Case, async: true

  @moduletag :socat

  test "destroy/1 kills the socat process" do
    {:ok, bus} = Jeff.VirtualBus.create()
    {:os_pid, os_pid} = Port.info(bus.socat_port, :os_pid)
    assert alive?(os_pid)

    Jeff.VirtualBus.destroy(bus.socat_port)

    # kill is asynchronous; give the OS a moment
    assert eventually(fn -> not alive?(os_pid) end)
  end

  defp eventually(fun, tries \\ 20) do
    cond do
      fun.() -> true
      tries == 1 -> false
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  defp alive?(os_pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end
end
