defmodule TymeslotWeb.Hooks.LoggerMetadataHookTest do
  @moduledoc false

  use ExUnit.Case, async: true

  @moduletag :hooks

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Infrastructure.CorrelationId
  alias TymeslotWeb.Hooks.LoggerMetadataHook

  defp build_socket(assigns \\ %{}) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)
    }
  end

  # A connected socket has a non-nil transport_pid, which is what
  # Phoenix.LiveView.connected?/1 checks internally.
  defp build_connected_socket(assigns \\ %{}) do
    %Socket{
      transport_pid: self(),
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)
    }
  end

  describe "on_mount(:default, ...)" do
    test "generates correlation_id and sets it in socket assigns, process dict, and Logger metadata" do
      socket = build_socket()

      assert {:cont, updated_socket} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, socket)

      correlation_id = updated_socket.assigns[:correlation_id]

      assert correlation_id =~
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert CorrelationId.get_from_process() == correlation_id
      assert Logger.metadata()[:correlation_id] == correlation_id
    end

    test "preserves existing correlation_id from socket assigns" do
      existing_id = CorrelationId.generate()
      socket = build_socket(%{correlation_id: existing_id})

      assert {:cont, updated_socket} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, socket)

      assert updated_socket.assigns[:correlation_id] == existing_id
      assert CorrelationId.get_from_process() == existing_id
      assert Logger.metadata()[:correlation_id] == existing_id
    end

    test "adopts the request correlation_id from the process dictionary (dead render)" do
      # Simulates the initial HTTP render: the CorrelationId plug has already set
      # an id in the process dictionary for this request. The hook must adopt it
      # rather than minting a new one, so the request's start and stop log lines
      # share a single correlation_id.
      request_id = CorrelationId.generate()
      CorrelationId.put_in_process(request_id)
      socket = build_socket()

      assert {:cont, updated_socket} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, socket)

      assert updated_socket.assigns[:correlation_id] == request_id
      assert CorrelationId.get_from_process() == request_id
      assert Logger.metadata()[:correlation_id] == request_id
    end

    test "mints a fresh correlation_id on a connected mount even when process dict holds a stale id" do
      # Simulates a live_redirect or push_navigate: the channel process is reused,
      # so the process dictionary still contains the previous mount's correlation_id.
      # The hook must ignore it and generate a new id for this mount.
      stale_id = CorrelationId.generate()
      CorrelationId.put_in_process(stale_id)
      socket = build_connected_socket()

      assert {:cont, updated_socket} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, socket)

      fresh_id = updated_socket.assigns[:correlation_id]

      assert fresh_id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      refute fresh_id == stale_id
      assert CorrelationId.get_from_process() == fresh_id
      assert Logger.metadata()[:correlation_id] == fresh_id
    end

    test "sets user_id in Logger metadata when current_user is assigned" do
      user = %{id: 42}
      socket = build_socket(%{current_user: user})

      assert {:cont, _socket} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, socket)

      assert Logger.metadata()[:user_id] == 42
    end

    test "does not set user_id when current_user is nil" do
      socket = build_socket(%{current_user: nil})

      assert {:cont, _socket} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, socket)

      refute Keyword.has_key?(Logger.metadata(), :user_id)
    end

    test "does not set user_id when current_user is absent" do
      socket = build_socket()

      assert {:cont, _socket} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, socket)

      refute Keyword.has_key?(Logger.metadata(), :user_id)
    end
  end
end
