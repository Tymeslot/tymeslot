defmodule TymeslotWeb.OnboardingLive.WeekReveal do
  @moduledoc """
  Reads the host's coming week for the stage once they have a bookable
  calendar, and folds the answer into `@stage_week`.

  `start/1` sets the week to `:loading`, bumps `reveal_key` so the times
  reveal when they arrive, and reads the week with `start_async/3`, never in
  the disconnected render. A read still going after a few seconds turns the
  week `:slow`; it can still arrive and turn it `:ready`. A read that fails
  or crashes turns it `:failed`, which never blocks the host: the stage then
  says the free times will appear on the page.

  The week is socket state, so it carries into the later steps. It is read
  once per mount: on the connected mount of any step when a bookable
  calendar is already there (a reload, a resume, an OAuth return), and again
  when the host connects one on the calendar step.
  """

  require Logger
  require Phoenix.LiveView

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Availability
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias TymeslotWeb.OnboardingLive.LivePreview

  @slow_after_ms 4_000

  @doc """
  The week a render shows before any read has answered: `:loading` for a
  host with a bookable calendar, whose read is about to start, so they never
  see the line meant for a host without one; the placeholder otherwise.
  """
  @spec initial_week(boolean() | nil) :: map()
  def initial_week(true), do: %{state: :loading, preview: nil}
  def initial_week(_bookable), do: %{state: :placeholder, preview: nil}

  @doc """
  Starts reading the week when the page has a bookable calendar and the
  socket is connected; otherwise leaves the socket as it is. A read already
  in flight is cancelled first, since a second `start_async/3` under the
  same name would silently drop the first one's answer.
  """
  @spec maybe_start(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_start(%{assigns: %{booking_page_live: true, profile: %{}}} = socket) do
    if LiveView.connected?(socket), do: start(socket), else: socket
  end

  def maybe_start(socket), do: socket

  defp start(socket) do
    profile = socket.assigns.profile
    key = socket.assigns.reveal_key + 1
    Process.send_after(self(), {:week_preview_slow, key}, slow_after_ms())

    socket
    |> LiveView.cancel_async(:week_preview)
    |> Component.assign(
      stage_week: %{state: :loading, preview: nil},
      stage_announcement: "",
      reveal_key: key
    )
    |> LiveView.start_async(
      :week_preview,
      Tasks.with_context(fn -> Availability.week_preview(profile) end)
    )
  end

  @doc """
  Folds the read's answer into the week. Dispatched from
  `OnboardingLive.handle_async/3`.
  """
  @spec handle_result({:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_result({:ok, {:ok, preview}}, socket), do: put_week(socket, :ready, preview)

  def handle_result({:ok, {:error, _reason}}, socket), do: put_week(socket, :failed, nil)

  # A read cancelled without a new one taking its place (a debug fixture
  # stood in for it) leaves the week to whatever replaced it.
  def handle_result({:exit, {:shutdown, :cancel}}, socket), do: socket

  def handle_result({:exit, reason}, socket) do
    Logger.warning("Onboarding week preview crashed",
      user_id: socket.assigns.current_user.id,
      reason: LogFormat.reason(reason)
    )

    put_week(socket, :failed, nil)
  end

  @doc """
  Marks the week slow when the read it was armed for is still loading. The
  timer can fire after the answer, or after a newer read began; both leave
  the week alone.
  """
  @spec handle_slow(integer(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_slow(key, %{assigns: %{reveal_key: key, stage_week: %{state: :loading}}} = socket),
    do: put_week(socket, :slow, nil)

  def handle_slow(_key, socket), do: socket

  defp put_week(socket, state, preview) do
    week = %{state: state, preview: preview}

    Component.assign(socket,
      stage_week: week,
      stage_announcement: LivePreview.week_caption(week) || ""
    )
  end

  # Configurable so a test can watch the slow state without waiting for it.
  defp slow_after_ms,
    do: Application.get_env(:tymeslot, :onboarding_week_slow_after_ms, @slow_after_ms)
end
