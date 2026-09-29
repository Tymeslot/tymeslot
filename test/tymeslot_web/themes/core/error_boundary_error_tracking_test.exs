defmodule TymeslotWeb.Themes.Core.ErrorBoundaryErrorTrackingTest do
  @moduledoc """
  The theme error boundary keeps a buggy theme from crashing the booking
  page, and records what it caught so the bug does not go unnoticed.
  """

  # async: false: ErrorTracker's `enabled` switch is global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :themes

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Core.ErrorBoundary

  defmodule RaisingTheme do
    @moduledoc false
    @spec handle_event(String.t(), map(), Socket.t()) :: no_return()
    def handle_event(_event, _params, _socket), do: raise("boom event")
  end

  test "a theme callback that raises is recorded with the theme and callback" do
    with_config(:error_tracker, enabled: true)
    socket = %Socket{assigns: %{__changed__: %{}, flash: %{}}}

    capture_log(fn ->
      assert {:noreply, _socket} =
               ErrorBoundary.wrap_callback("buggy", RaisingTheme, :handle_event, [
                 "click",
                 %{},
                 socket
               ])
    end)

    assert [%Error{kind: "Elixir.RuntimeError", reason: "boom event"} = error] =
             Error |> Repo.all() |> Repo.preload(:occurrences)

    assert [%{context: %{"theme_id" => "buggy", "function" => "handle_event"}}] =
             error.occurrences
  end
end
