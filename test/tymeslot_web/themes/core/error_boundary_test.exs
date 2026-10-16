defmodule TymeslotWeb.Themes.Core.ErrorBoundaryTest do
  @moduledoc """
  Verifies the theme error boundary catches raises and throws from theme
  callbacks and assigns a structured error onto the socket instead of crashing
  the LiveView. Without this safety net, a buggy theme would 500 the entire
  booking page.
  """

  use ExUnit.Case, async: true

  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Core.ErrorBoundary

  # Theme module stubs used by wrap_callback/4

  defmodule HappyTheme do
    @moduledoc false
    alias Phoenix.Component
    alias Phoenix.LiveView.Socket
    @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
    def mount(_params, _session, socket), do: {:ok, Component.assign(socket, :ok, true)}

    @spec handle_params(map(), String.t(), Socket.t()) :: {:noreply, Socket.t()}
    def handle_params(_params, _url, socket), do: {:noreply, socket}

    @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
    def handle_event(_event, _params, socket), do: {:noreply, socket}

    @spec handle_info(term(), Socket.t()) :: {:noreply, Socket.t()}
    def handle_info(_msg, socket), do: {:noreply, socket}

    @spec handle_async(term(), term(), Socket.t()) :: {:noreply, Socket.t()}
    def handle_async(_name, _result, socket),
      do: {:noreply, Component.assign(socket, :async, true)}
  end

  defmodule RaisingTheme do
    @moduledoc false
    alias Phoenix.LiveView.Socket
    @spec mount(map(), map(), Socket.t()) :: no_return()
    def mount(_params, _session, _socket), do: raise("boom mount")

    @spec handle_params(map(), String.t(), Socket.t()) :: no_return()
    def handle_params(_params, _url, _socket), do: raise("boom params")

    @spec handle_event(String.t(), map(), Socket.t()) :: no_return()
    def handle_event(_event, _params, _socket), do: raise("boom event")

    @spec handle_info(term(), Socket.t()) :: no_return()
    def handle_info(_msg, _socket), do: raise("boom info")

    @spec handle_async(term(), term(), Socket.t()) :: no_return()
    def handle_async(_name, _result, _socket), do: raise("boom async")
  end

  defmodule ThrowingTheme do
    @moduledoc false
    alias Phoenix.LiveView.Socket
    @spec mount(map(), map(), Socket.t()) :: no_return()
    def mount(_params, _session, _socket), do: throw(:thrown_mount)

    @spec handle_event(String.t(), map(), Socket.t()) :: no_return()
    def handle_event(_event, _params, _socket), do: throw(:thrown_event)
  end

  defp socket, do: %Socket{assigns: %{__changed__: %{}, flash: %{}}}

  describe "wrap_callback/4 — happy path" do
    test "mount returns the wrapped module's result unchanged" do
      assert {:ok, socket} =
               ErrorBoundary.wrap_callback("happy", HappyTheme, :mount, [%{}, %{}, socket()])

      assert socket.assigns[:ok] == true
    end

    test "handle_event returns the wrapped module's result unchanged" do
      assert {:noreply, _socket} =
               ErrorBoundary.wrap_callback("happy", HappyTheme, :handle_event, [
                 "click",
                 %{},
                 socket()
               ])
    end
  end

  describe "wrap_callback/4 with handle_async" do
    test "returns the wrapped module's result unchanged" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback("happy", HappyTheme, :handle_async, [
                 {:week_slots, ~D[2027-03-08]},
                 {:ok, {:ok, %{}}},
                 socket()
               ])

      assert socket.assigns[:async] == true
    end

    @tag :capture_log
    test "turns a raise into the page's update error instead of a crash" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback("raising", RaisingTheme, :handle_async, [
                 {:week_slots, ~D[2027-03-08]},
                 {:ok, {:ok, %{}}},
                 socket()
               ])

      assert socket.assigns.theme_error.function == :handle_async

      assert socket.assigns.theme_error_message ==
               "This page could not be updated. Please try again."
    end
  end

  describe "wrap_callback/4 — raise" do
    test "mount that raises is caught and a theme_error is assigned" do
      assert {:ok, socket} =
               ErrorBoundary.wrap_callback("buggy", RaisingTheme, :mount, [%{}, %{}, socket()])

      assert %RuntimeError{message: "boom mount"} = socket.assigns.theme_error.error
      assert socket.assigns.theme_error.theme_id == "buggy"

      assert socket.assigns.theme_error_message ==
               "This page could not be loaded. Please try again."

      assert socket.assigns.theme_error.function == :mount
    end

    test "handle_params that raises returns noreply with theme_error assigned" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback(
                 "buggy",
                 RaisingTheme,
                 :handle_params,
                 [%{}, "/", socket()]
               )

      assert socket.assigns.theme_error_message ==
               "This step could not be opened. Please try again."

      assert %RuntimeError{message: "boom params"} = socket.assigns.theme_error.error
      assert socket.assigns.theme_error.function == :handle_params
    end

    test "handle_event that raises is caught and records the failing callback" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback(
                 "buggy",
                 RaisingTheme,
                 :handle_event,
                 ["click", %{}, socket()]
               )

      assert socket.assigns.theme_error_message ==
               "Your last action could not be completed. Please try again."

      assert %RuntimeError{message: "boom event"} = socket.assigns.theme_error.error
      assert socket.assigns.theme_error.function == :handle_event
    end

    test "handle_info that raises is caught and records the failing callback" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback("buggy", RaisingTheme, :handle_info, [
                 :ping,
                 socket()
               ])

      assert socket.assigns.theme_error_message ==
               "This page could not be updated. Please try again."

      assert %RuntimeError{message: "boom info"} = socket.assigns.theme_error.error
      assert socket.assigns.theme_error.function == :handle_info
    end
  end

  describe "wrap_callback/4 — throw" do
    test "a thrown value during mount is caught" do
      assert {:ok, socket} =
               ErrorBoundary.wrap_callback("buggy", ThrowingTheme, :mount, [%{}, %{}, socket()])

      assert socket.assigns.theme_error_message ==
               "This page could not be loaded. Please try again."

      assert socket.assigns.theme_error.error == {:throw, :thrown_mount}
      assert socket.assigns.theme_error.function == :mount
    end

    test "a thrown value during handle_event is caught" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback("buggy", ThrowingTheme, :handle_event, [
                 "click",
                 %{},
                 socket()
               ])

      assert socket.assigns.theme_error.error == {:throw, :thrown_event}
      assert socket.assigns.theme_error.function == :handle_event

      assert socket.assigns.theme_error_message ==
               "Your last action could not be completed. Please try again."
    end
  end

  describe "format_error/1" do
    test "falls back to a generic message" do
      assert ErrorBoundary.format_error(%{function: :something_else}) ==
               "Something went wrong on this page. Please try again."
    end
  end
end
