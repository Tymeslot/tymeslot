defmodule TymeslotWeb.Themes.Shared.InfoHandlers do
  @moduledoc """
  Shared handle_info handlers for theme scheduling LiveViews.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]
  require Logger

  alias TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent
  alias TymeslotWeb.Live.Scheduling.Helpers

  @doc """
  Handles calendar events updated via PubSub.

  Re-fetches the month availability map and clears any cached slot data
  so the scheduling page reflects the latest calendar state.
  """
  @spec handle_calendar_events_updated(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_calendar_events_updated(socket) do
    socket =
      case socket.assigns[:current_state] do
        state when state in [:overview, :schedule, nil] ->
          socket
          |> assign(:available_slots, nil)
          |> assign(:selected_time, nil)
          |> Helpers.fetch_month_availability_async()

        _committed ->
          Helpers.fetch_month_availability_async(socket)
      end

    {:noreply, socket}
  end

  @doc """
  Handles month availability fetch completion (success).
  """
  @spec handle_availability_ok(Phoenix.LiveView.Socket.t(), reference(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_availability_ok(socket, ref, availability_map) do
    Process.demonitor(ref, [:flush])

    # Check if this is our current availability task
    if ref == socket.assigns[:availability_task_ref] do
      socket =
        socket
        |> assign(:month_availability_map, availability_map)
        |> assign(:availability_status, :loaded)
        |> assign(:availability_task, nil)
        |> assign(:availability_task_ref, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @doc """
  Handles month availability fetch completion (error).
  """
  @spec handle_availability_error(Phoenix.LiveView.Socket.t(), reference(), any()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_availability_error(socket, ref, reason) do
    Process.demonitor(ref, [:flush])

    if ref == socket.assigns[:availability_task_ref] do
      Logger.warning("Month availability fetch failed", reason: inspect(reason))

      socket =
        socket
        |> assign(:month_availability_map, nil)
        |> assign(:availability_status, :error)
        |> assign(:availability_task, nil)
        |> assign(:availability_task_ref, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @doc """
  Handle task crash or timeout.
  """
  @spec handle_availability_down(Phoenix.LiveView.Socket.t(), reference(), any()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_availability_down(socket, ref, reason) do
    if ref == socket.assigns[:availability_task_ref] do
      Logger.warning("Month availability task failed", reason: inspect(reason))

      socket =
        socket
        |> assign(:month_availability_map, nil)
        |> assign(:availability_status, :timeout)
        |> assign(:availability_task, nil)
        |> assign(:availability_task_ref, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @doc """
  Handles common dropdown closing logic.
  """
  @spec handle_close_dropdown(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_dropdown(socket) do
    {:noreply, assign(socket, :timezone_dropdown_open, false)}
  end

  @doc """
  Handles fetching available slots.
  """
  @spec handle_fetch_available_slots(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          String.t() | integer(),
          String.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_fetch_available_slots(socket, date, duration, timezone) do
    case SlotFetchingHandlerComponent.fetch_available_slots(socket, date, duration, timezone) do
      {:ok, updated_socket} -> {:noreply, updated_socket}
      {:error, updated_socket} -> {:noreply, updated_socket}
    end
  end

  @doc """
  Handles loading slots for a specific date.
  """
  @spec handle_load_slots(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_load_slots(socket, date) do
    case SlotFetchingHandlerComponent.load_slots(socket, date) do
      {:ok, updated_socket} -> {:noreply, updated_socket}
    end
  end

  @doc """
  Handles the `:paid` PubSub broadcast for an embedded paid booking.

  The booker iframe subscribed to `meeting_payment:<meeting_id>` when it
  pushed Stripe Checkout to a new tab; when the webhook confirms the
  payment we flip the iframe directly to the theme's `:confirmation`
  view so the attendee never sees Stripe inside the host's page.
  """
  @spec handle_payment_paid(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t(), atom(), map() -> Phoenix.LiveView.Socket.t())
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_payment_paid(socket, transition_fun) do
    case socket.assigns[:awaiting_payment_meeting] do
      %{} = meeting ->
        socket =
          socket
          |> assign(:meeting_uid, meeting.uid)
          |> assign(:name, meeting.attendee_name)
          |> assign(:email, meeting.attendee_email)

        {:noreply, transition_fun.(socket, :confirmation, %{})}

      _other ->
        {:noreply, socket}
    end
  end

  @doc """
  Handles the `:expired` PubSub broadcast for an embedded paid booking.

  When the Stripe Checkout session expires (attendee closed the tab,
  30 minutes elapsed, etc.) we send the booker back to the booking form
  with a flash so they can try again.
  """
  @spec handle_payment_expired(
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t(), atom(), map() -> Phoenix.LiveView.Socket.t())
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_payment_expired(socket, transition_fun) do
    socket =
      socket
      |> assign(:awaiting_payment_meeting, nil)
      |> assign(:awaiting_payment_checkout_url, nil)
      |> assign(:submission_processed, false)
      |> put_flash(:error, "Payment was cancelled. Please try booking again.")

    {:noreply, transition_fun.(socket, :booking, %{})}
  end
end
