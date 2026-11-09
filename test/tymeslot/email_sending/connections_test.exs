defmodule Tymeslot.EmailSending.ConnectionsTest do
  @moduledoc "Verifies owner-scoped SMTP reservations release on return and holder death."

  use ExUnit.Case, async: false

  @moduletag :emails
  @moduletag :security

  import ExUnit.CaptureLog

  alias Tymeslot.EmailSending.Connections

  test "all ten owner slots must be full before another connection is refused" do
    owner_id = System.unique_integer([:positive])
    assert Connections.limit() == 10
    holders = for _slot <- 1..Connections.limit(), do: hold(owner_id)

    assert {:error, :rate_limited} =
             Connections.with_owner(owner_id, fn -> send(self(), :unexpected_work) end)

    refute_received :unexpected_work

    assert {:ok, :other_owner} =
             Connections.with_owner(owner_id + 1, fn -> {:ok, :other_owner} end)

    {holder, monitor} = hd(holders)
    send(holder, :release)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
    assert {:ok, :released} = Connections.with_owner(owner_id, fn -> {:ok, :released} end)
  end

  test "a dead holder cannot keep an owner permanently blocked" do
    owner_id = System.unique_integer([:positive])
    holders = for _slot <- 1..Connections.limit(), do: hold(owner_id)
    {holder, monitor} = hd(holders)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}

    assert {:ok, :recovered} = Connections.with_owner(owner_id, fn -> {:ok, :recovered} end)
  end

  test "callback exceptions are sanitized and still release the reservation" do
    owner_id = System.unique_integer([:positive])
    for _slot <- 1..(Connections.limit() - 1), do: hold(owner_id)

    log =
      capture_log(fn ->
        assert {:error, :connection_unavailable} =
                 Connections.with_owner(owner_id, fn -> raise "smtp-password-secret" end)
      end)

    refute log =~ "smtp-password-secret"
    assert {:ok, :released} = Connections.with_owner(owner_id, fn -> {:ok, :released} end)
  end

  test "a callback returning a lock-shaped error runs only once" do
    owner_id = System.unique_integer([:positive])

    assert {:error, :refresh_in_progress} =
             Connections.with_owner(owner_id, fn ->
               send(self(), :ran)
               {:error, :refresh_in_progress}
             end)

    assert_received :ran
    refute_received :ran
  end

  test "invalid owners cannot run unreserved work" do
    for owner <- [nil, 0, -1, "123"] do
      assert {:error, :invalid_owner} =
               Connections.with_owner(owner, fn -> send(self(), :unexpected_work) end)
    end

    refute_received :unexpected_work
  end

  defp hold(owner_id) do
    parent = self()

    {holder, monitor} =
      spawn_monitor(fn ->
        Connections.with_owner(owner_id, fn ->
          send(parent, {:reserved, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
    assert_receive {:reserved, ^holder}
    {holder, monitor}
  end
end
