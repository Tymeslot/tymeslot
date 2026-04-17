defmodule TymeslotWeb.Plugs.LoggerMetadataIsolationTest do
  @moduledoc """
  Regression tests for per-request Logger metadata isolation.

  Before the fix, `SetLoggerMetadata` and `LoggerMetadataHook` both wrote
  `user_id` with `Logger.metadata/1` but never cleared it. Cowboy/Bandit
  reuse worker processes across requests, so an anonymous request landing
  on a worker that previously served an authenticated user would inherit
  that user's id in its log lines. These tests simulate two sequential
  invocations on the same process and assert that the second one does not
  inherit the first's `user_id`.
  """

  use ExUnit.Case, async: false

  @moduletag :plugs

  require Logger

  alias Phoenix.LiveView.Socket
  alias Plug.Conn
  alias Plug.Test, as: PlugTest
  alias TymeslotWeb.Hooks.LoggerMetadataHook
  alias TymeslotWeb.Plugs.SetLoggerMetadata

  setup do
    on_exit(fn -> Logger.reset_metadata() end)
    Logger.reset_metadata()
    :ok
  end

  describe "SetLoggerMetadata.call/2" do
    test "second anonymous conn on the same process does not inherit user_id from the first" do
      # Request A: authenticated user lands on this worker.
      conn_a =
        PlugTest.conn(:get, "/")
        |> Conn.assign(:current_user, %{id: "user-a"})
        |> SetLoggerMetadata.call([])

      assert Logger.metadata()[:user_id] == "user-a"
      refute conn_a.halted

      # Request B: next request on the same worker is anonymous.
      conn_b = SetLoggerMetadata.call(PlugTest.conn(:get, "/"), [])

      refute conn_b.halted
      refute Logger.metadata()[:user_id]
    end

    test "third request's user_id does not inherit from the second" do
      # Request A: user-a
      PlugTest.conn(:get, "/")
      |> Conn.assign(:current_user, %{id: "user-a"})
      |> SetLoggerMetadata.call([])

      # Request B: user-b — must overwrite, never merge.
      PlugTest.conn(:get, "/")
      |> Conn.assign(:current_user, %{id: "user-b"})
      |> SetLoggerMetadata.call([])

      assert Logger.metadata()[:user_id] == "user-b"

      # Request C: anonymous — must drop back to nil.
      SetLoggerMetadata.call(PlugTest.conn(:get, "/"), [])

      refute Logger.metadata()[:user_id]
    end
  end

  describe "LoggerMetadataHook.on_mount/4" do
    test "second anonymous mount on the same process does not inherit user_id" do
      # Mount A: authenticated user.
      assert {:cont, _socket_a} =
               LoggerMetadataHook.on_mount(
                 :default,
                 %{},
                 %{},
                 build_socket(%{current_user: %{id: "user-a"}})
               )

      assert Logger.metadata()[:user_id] == "user-a"

      # Mount B: anonymous mount on the same process.
      assert {:cont, _socket_b} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, build_socket())

      refute Logger.metadata()[:user_id]
    end

    test "second mount generates a fresh correlation_id and does not inherit the first's" do
      assert {:cont, socket_a} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, build_socket())

      correlation_a = socket_a.assigns[:correlation_id]
      assert is_binary(correlation_a)

      # Next mount on the same process must generate its own id.
      assert {:cont, socket_b} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, build_socket())

      correlation_b = socket_b.assigns[:correlation_id]

      assert is_binary(correlation_b)
      assert correlation_b != correlation_a
      assert Logger.metadata()[:correlation_id] == correlation_b
    end
  end

  defp build_socket(assigns \\ %{}) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)
    }
  end
end
