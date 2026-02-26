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

  describe "on_mount(:default, ...)" do
    test "generates correlation_id and sets it in socket assigns, process dict, and Logger metadata" do
      socket = build_socket()

      assert {:cont, updated_socket} =
               LoggerMetadataHook.on_mount(:default, %{}, %{}, socket)

      correlation_id = updated_socket.assigns[:correlation_id]

      assert is_binary(correlation_id)
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
