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

  `refresh/1` reads it again after the host changed what the week offers
  (their hours, or the meeting's length or place, on the meeting step). A
  week already shown stays in place while the new one is read, so the
  times never blink back to loading; the new week replaces it and reveals
  as any new week does. The read in flight carries its key in
  `pending_reveal_key` until it answers. Changes close together are read
  once (`handle_refresh/2`), and a refresh that fails keeps the week shown,
  marked `stale: true`, which the caption owns up to.

  Each read `start/1` begins reports once how it went
  (`calendar_reveal_loaded`): `ok` or `failed` when it answers while the
  week is loading, `slow` when the timer fires first, after which the late
  answer is not reported again. Refreshes report nothing: the week was
  already revealed.
  """

  require Logger
  require Phoenix.LiveView

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Availability
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias TymeslotWeb.Analytics

  @slow_after_ms 4_000
  @refresh_after_ms 300

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

  @doc """
  Reads the week again after the host changed what it offers. A ready week
  stays on the stage until the new one arrives; any other state starts
  over as `maybe_start/1` does.

  Changes close together are read once: each call re-arms one short timer
  (`handle_refresh/2`) under a new token, and only the latest token's timer
  reads, so five day toggles in a row cost one read. A read already in
  flight when it fires is cancelled, so the latest change always wins.
  """
  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(
        %{assigns: %{booking_page_live: true, profile: %{}, stage_week: %{state: :ready}}} =
          socket
      ) do
    if LiveView.connected?(socket) do
      token = make_ref()
      Process.send_after(self(), {:week_preview_refresh, token}, refresh_after_ms())
      Component.assign(socket, :refresh_token, token)
    else
      socket
    end
  end

  def refresh(socket), do: maybe_start(socket)

  @doc """
  Reads the week for the latest `refresh/1`, when `token` is still the
  latest one; an earlier timer leaves the socket as it is. Dispatched from
  `OnboardingLive.handle_info/2`.
  """
  @spec handle_refresh(reference(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_refresh(token, %{assigns: %{refresh_token: token}} = socket),
    do: socket |> Component.assign(:refresh_token, nil) |> start_refresh()

  def handle_refresh(_token, socket), do: socket

  defp start_refresh(socket) do
    profile = socket.assigns.profile
    key = max(socket.assigns.reveal_key, socket.assigns[:pending_reveal_key] || 0) + 1

    socket
    |> LiveView.cancel_async(:week_preview)
    |> Component.assign(:pending_reveal_key, key)
    |> LiveView.start_async(
      :week_preview,
      Tasks.with_context(fn -> {key, Availability.week_preview(profile)} end)
    )
  end

  defp start(socket) do
    profile = socket.assigns.profile
    key = socket.assigns.reveal_key + 1
    Process.send_after(self(), {:week_preview_slow, key}, slow_after_ms())

    socket
    |> LiveView.cancel_async(:week_preview)
    |> Component.assign(
      stage_week: %{state: :loading, preview: nil},
      reveal_key: key,
      pending_reveal_key: nil
    )
    |> LiveView.start_async(
      :week_preview,
      Tasks.with_context(fn -> {key, Availability.week_preview(profile)} end)
    )
  end

  @doc """
  Folds the read's answer into the week. Dispatched from
  `OnboardingLive.handle_async/3`.

  The answer carries the `reveal_key` its read was started under, and one
  for an older key is dropped: a debug fixture that stood in for the read
  bumps the key, so an answer already on its way cannot replace the
  fixture's week.
  """
  @spec handle_result({:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  # A refresh's answer takes the key it was read under, so its times are a
  # new list that reveals.
  #
  # A refresh that fails keeps the week already shown, marked `stale`, so
  # the stage says it could not catch up rather than dropping the times.
  def handle_result({:ok, {key, {:ok, preview}}}, %{assigns: %{pending_reveal_key: key}} = socket) do
    socket
    |> Component.assign(reveal_key: key, pending_reveal_key: nil)
    |> put_week(:ready, preview)
  end

  def handle_result(
        {:ok, {key, {:error, _reason}}},
        %{assigns: %{pending_reveal_key: key}} = socket
      ),
      do: keep_stale(socket)

  def handle_result({:ok, {key, {:ok, preview}}}, %{assigns: %{reveal_key: key}} = socket),
    do: socket |> report_reveal("ok") |> put_week(:ready, preview)

  def handle_result({:ok, {key, {:error, _reason}}}, %{assigns: %{reveal_key: key}} = socket),
    do: socket |> report_reveal("failed") |> put_week(:failed, nil)

  def handle_result({:ok, {_stale_key, _result}}, socket), do: socket

  # A read cancelled without a new one taking its place (a debug fixture
  # stood in for it) leaves the week to whatever replaced it.
  def handle_result({:exit, {:shutdown, :cancel}}, socket), do: socket

  def handle_result({:exit, reason}, socket) do
    Logger.warning("Onboarding week preview crashed",
      user_id: socket.assigns.current_user.id,
      reason: LogFormat.reason(reason)
    )

    if socket.assigns[:pending_reveal_key],
      do: keep_stale(socket),
      else: socket |> report_reveal("failed") |> put_week(:failed, nil)
  end

  # Only the first word on a read counts: a week no longer loading has
  # already been reported, as `slow`.
  defp report_reveal(%{assigns: %{stage_week: %{state: :loading}}} = socket, result),
    do: Analytics.push(socket, "calendar_reveal_loaded", %{result: result})

  defp report_reveal(socket, _result), do: socket

  defp keep_stale(socket) do
    socket
    |> Component.assign(:pending_reveal_key, nil)
    |> Component.update(:stage_week, &Map.put(&1, :stale, true))
  end

  @doc """
  Marks the week slow when the read it was armed for is still loading. The
  timer can fire after the answer, or after a newer read began; both leave
  the week alone.
  """
  @spec handle_slow(integer(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_slow(key, %{assigns: %{reveal_key: key, stage_week: %{state: :loading}}} = socket),
    do: socket |> report_reveal("slow") |> put_week(:slow, nil)

  def handle_slow(_key, socket), do: socket

  defp put_week(socket, state, preview),
    do: Component.assign(socket, :stage_week, %{state: state, preview: preview})

  # How long a refresh waits for the next change before it reads; a test
  # sets it to nothing.
  defp refresh_after_ms,
    do: Application.get_env(:tymeslot, :onboarding_week_refresh_after_ms, @refresh_after_ms)

  # Configurable so a test can watch the slow state without waiting for it.
  defp slow_after_ms,
    do: Application.get_env(:tymeslot, :onboarding_week_slow_after_ms, @slow_after_ms)
end
