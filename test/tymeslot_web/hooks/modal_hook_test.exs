defmodule TymeslotWeb.Hooks.ModalHookTest do
  use ExUnit.Case, async: true
  @moduletag :hooks
  @moduletag :ui

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Hooks.ModalHook

  describe "with_modal_data/3" do
    test "invokes the function with the modal data when it is present" do
      socket = %Socket{assigns: %{cancel_meeting_modal_data: %{id: 42}}}

      assert {:ok, %{id: 42}} =
               ModalHook.with_modal_data(socket, :cancel_meeting, fn data -> {:ok, data} end)
    end

    test "short-circuits to a no-op when the modal data is nil (duplicate confirm)" do
      socket = %Socket{assigns: %{cancel_meeting_modal_data: nil}}

      assert {:noreply, ^socket} =
               ModalHook.with_modal_data(socket, :cancel_meeting, fn _data ->
                 flunk("the function must not run when the modal data is already cleared")
               end)
    end

    test "resolves string modal names as well as atoms" do
      socket = %Socket{assigns: %{delete_break_modal_data: %{id: 7}}}

      assert {:ok, %{id: 7}} =
               ModalHook.with_modal_data(socket, "delete_break", fn data -> {:ok, data} end)
    end
  end

  describe "a modal Core does not register" do
    test "is opened and closed by its own {show_key, data_key}" do
      keys = {:show_unregistered_modal, :unregistered_modal_data}

      socket = ModalHook.mount_modal(%Socket{}, [{keys, false}])
      refute socket.assigns.show_unregistered_modal

      socket = ModalHook.show_modal(socket, keys, %{id: 3})
      assert socket.assigns.show_unregistered_modal
      assert socket.assigns.unregistered_modal_data == %{id: 3}

      socket = ModalHook.hide_modal(socket, keys)
      refute socket.assigns.show_unregistered_modal
      assert socket.assigns.unregistered_modal_data == nil
    end

    test "is rejected by name" do
      assert_raise ArgumentError, fn -> ModalHook.show_modal(%Socket{}, :unregistered) end
    end
  end
end
