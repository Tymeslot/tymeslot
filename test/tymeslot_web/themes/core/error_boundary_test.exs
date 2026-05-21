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

  describe "wrap_callback/4 — raise" do
    test "mount that raises is caught and a theme_error is assigned" do
      assert {:ok, socket} =
               ErrorBoundary.wrap_callback("buggy", RaisingTheme, :mount, [%{}, %{}, socket()])

      assert %RuntimeError{message: "boom mount"} = socket.assigns.theme_error.error
      assert socket.assigns.theme_error.theme_id == "buggy"
      assert socket.assigns.theme_error_message == "Failed to load theme"
    end

    test "handle_params that raises returns noreply with theme_error assigned" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback(
                 "buggy",
                 RaisingTheme,
                 :handle_params,
                 [%{}, "/", socket()]
               )

      assert socket.assigns.theme_error_message == "Navigation error in theme"
    end

    test "handle_event that raises is caught with the right error message" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback(
                 "buggy",
                 RaisingTheme,
                 :handle_event,
                 ["click", %{}, socket()]
               )

      assert socket.assigns.theme_error_message == "Event handling error in theme"
    end

    test "handle_info that raises is caught with the right error message" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback("buggy", RaisingTheme, :handle_info, [
                 :ping,
                 socket()
               ])

      assert socket.assigns.theme_error_message == "Message handling error in theme"
    end
  end

  describe "wrap_callback/4 — throw" do
    test "a thrown value during mount is caught" do
      assert {:ok, socket} =
               ErrorBoundary.wrap_callback("buggy", ThrowingTheme, :mount, [%{}, %{}, socket()])

      assert socket.assigns.theme_error_message == "Failed to load theme"
    end

    test "a thrown value during handle_event is caught" do
      assert {:noreply, socket} =
               ErrorBoundary.wrap_callback("buggy", ThrowingTheme, :handle_event, [
                 "click",
                 %{},
                 socket()
               ])

      assert socket.assigns.theme_error_message == "Event handling error in theme"
    end
  end

  describe "format_error/1" do
    test "produces a function-specific message" do
      assert ErrorBoundary.format_error(%{function: :mount}) == "Failed to load theme"

      assert ErrorBoundary.format_error(%{function: :handle_params}) ==
               "Navigation error in theme"

      assert ErrorBoundary.format_error(%{function: :handle_event}) ==
               "Event handling error in theme"

      assert ErrorBoundary.format_error(%{function: :handle_info}) ==
               "Message handling error in theme"
    end

    test "falls back to a generic message" do
      assert ErrorBoundary.format_error(%{function: :something_else}) ==
               "An error occurred in the theme"
    end
  end
end
