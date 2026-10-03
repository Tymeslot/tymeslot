defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Autosave do
  @moduledoc """
  Auto-save orchestration for the meeting-type editor.

  When editing an existing meeting type, every change persists immediately so
  the saved state never depends on an explicit "save" action — closing the
  overlay, navigating away, or dropping the connection all leave the latest
  change already written. `MeetingTypeForm` calls `maybe_run/1` at the tail of
  each mutating event; this module owns the rate-limit guard, the
  serialise-and-persist step, and the resulting `:save_status` transitions.

  Creating a new meeting type is a no-op here: there is no record yet, so the
  explicit "Create meeting type" submit (`MeetingTypeForm.Creation`) owns
  that first save, after which the form is in edit mode.

  ## Save-status atoms

  | Atom          | Indicator copy                              | When set                                                  |
  |---------------|---------------------------------------------|-----------------------------------------------------------|
  | `:saved`      | "All changes saved"                         | Persist succeeded.                                        |
  | `:unsaved`    | "Unsaved changes"                           | Form is valid but in-flight (e.g. invalid-form pre-save). |
  | `:incomplete` | "Complete the form to save"                 | A required companion field is not yet set (video          |
  |               |                                             | provider or target calendar absent, or no price entered   |
  |               |                                             | yet when payment is required). Not a failure: the form    |
  |               |                                             | is legitimately in progress.                              |
  | `:throttled`  | "Too many changes - saving shortly…"        | Rate limit hit. A retry is automatically scheduled.       |
  | `:error`      | "Couldn't save changes"                     | The save was refused. Either the organiser's own input    |
  |               |                                             | (an entered price below the currency minimum, shown       |
  |               |                                             | beside the field and not logged), or an unexpected        |
  |               |                                             | persistence failure (changeset or context, logged).       |
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.FormHelpers
  alias Tymeslot.Venues
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Submission

  # Backoff before a throttled save is retried (milliseconds).
  @retry_after_ms 4_000

  @doc """
  Persists the current form state when editing; returns the socket unchanged
  while creating.
  """
  @spec maybe_run(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_run(%{assigns: %{is_edit: true}} = socket), do: run(socket)
  def maybe_run(socket), do: socket

  defp run(socket) do
    case RateLimiter.check_meeting_type_autosave_rate_limit(socket.assigns.current_user.id) do
      :ok ->
        socket.assigns
        |> Submission.build_params()
        |> Submission.persist(
          Helpers.get_security_metadata(socket),
          socket.assigns.type,
          socket.assigns.current_user
        )
        |> apply_result(socket)

      {:error, :rate_limited, _message} ->
        Process.send_after(self(), {:retry_autosave, socket.assigns.id}, @retry_after_ms)
        assign(socket, :save_status, :throttled)

      {:error, :invalid_user_id} ->
        assign(socket, :save_status, :error)
    end
  end

  # On success keep the freshly returned struct so later saves diff against the
  # latest persisted state. Invalid-form failures leave `form_errors` to the
  # per-field validators that already drive inline display.
  #
  # Companion-field-not-yet-set errors (:video_integration_required,
  # :target_calendar_required) and a price_cents error while no price has been
  # entered after enabling payment are expected incomplete states: the form is
  # legitimately in progress and no alarming error indicator should show.
  #
  # An entered price the changeset refuses is shown as :error with its message
  # beside the price input, and is not logged: it is the organiser's input,
  # not a fault. Genuine persistence failures (unexpected changeset errors,
  # unknown context errors) are logged and shown as :error.
  defp apply_result({:ok, updated}, socket) do
    socket
    |> assign(:type, updated)
    |> follow_dropped_venues(updated)
    |> assign(:form_errors, %{})
    |> assign(:save_status, :saved)
  end

  defp apply_result({:error, {:invalid_form, _errors}}, socket) do
    assign(socket, :save_status, :unsaved)
  end

  # Companion-field missing — video provider not yet chosen after switching to
  # video mode, or target calendar not yet chosen after changing the integration.
  # Surface as :incomplete (guidance), not :error.
  defp apply_result({:error, reason}, socket)
       when reason in [:video_integration_required, :target_calendar_required] do
    assign(socket, :save_status, :incomplete)
  end

  # Changeset failure where price_cents is the only failing field and no
  # price has been entered yet: payment was just toggled on. Treat as
  # :incomplete (guidance) so the "Couldn't save" indicator doesn't fire
  # before they've had a chance to fill in the price. A price that has been
  # entered but is refused (below the currency minimum, say) is a real error
  # and shows beside the price input like any other.
  defp apply_result({:error, %Ecto.Changeset{} = changeset}, socket)
       when socket.assigns.payment_required == true do
    errors = FormHelpers.format_changeset_errors(changeset)

    cond do
      Map.keys(errors) != [:price_cents] ->
        log_changeset_failure(socket)

        socket
        |> assign(:form_errors, errors)
        |> assign(:save_status, :error)

      price_blank?(socket.assigns.payment_price) ->
        assign(socket, :save_status, :incomplete)

      # The organiser's own input was refused, not a fault worth logging.
      true ->
        socket
        |> assign(:form_errors, errors)
        |> assign(:save_status, :error)
    end
  end

  defp apply_result({:error, %Ecto.Changeset{} = changeset}, socket) do
    log_changeset_failure(socket)

    socket
    |> assign(:form_errors, FormHelpers.format_changeset_errors(changeset))
    |> assign(:save_status, :error)
  end

  defp apply_result({:error, reason}, socket) do
    Logger.warning("Autosave context error",
      user_id: socket.assigns.current_user.id,
      meeting_type_id: socket.assigns.type.id,
      reason: LogFormat.reason(reason)
    )

    socket
    |> assign(:form_errors, FormHelpers.format_context_error(reason))
    |> assign(:save_status, :error)
  end

  defp log_changeset_failure(socket) do
    Logger.warning("Autosave changeset failure",
      user_id: socket.assigns.current_user.id,
      meeting_type_id: socket.assigns.type.id
    )
  end

  defp price_blank?(price) when is_binary(price), do: String.trim(price) == ""
  defp price_blank?(_price), do: true

  # A save can go through without venues the form still listed, when they
  # were deleted elsewhere meanwhile (see `Submission.persist/4`). The form
  # then takes the venue ids that were stored, and the organiser's current
  # venues, so it stops naming and offering the deleted ones.
  defp follow_dropped_venues(socket, updated) do
    stored = Map.new(MeetingTypes.location_options(updated), &{&1.id, &1.venue_ids})

    locations =
      Enum.map(socket.assigns.locations, fn location ->
        %{location | venue_ids: Map.get(stored, location.id, location.venue_ids)}
      end)

    if locations == socket.assigns.locations do
      socket
    else
      assign(socket,
        locations: locations,
        venues: Venues.list_venues(socket.assigns.current_user.id)
      )
    end
  end

  @doc """
  Subtle inline status shown beside the editor's "Done" button.

  Replaces the per-save flash toast that would otherwise fire on every change.
  """
  attr :status, :atom, required: true

  @spec indicator(map()) :: Phoenix.LiveView.Rendered.t()
  def indicator(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 text-token-sm" aria-live="polite">
      <%= case @status do %>
        <% :saved -> %>
          <.icon name="hero-check-circle-mini" class="w-4 h-4 text-green-500" />
          <span class="text-tymeslot-500">{dgettext("dashboard_meeting_form", "All changes saved")}</span>
        <% :error -> %>
          <.icon name="hero-exclamation-triangle-mini" class="w-4 h-4 text-red-500" />
          <span class="text-red-500">{dgettext("dashboard_meeting_form", "Couldn't save changes")}</span>
        <% :throttled -> %>
          <.icon name="hero-arrow-path-mini" class="w-4 h-4 text-amber-500 animate-spin" />
          <span class="text-amber-500">
            {dgettext("dashboard_meeting_form", "Too many changes - saving shortly…")}
          </span>
        <% :incomplete -> %>
          <.icon name="hero-information-circle-mini" class="w-4 h-4 text-tymeslot-400" />
          <span class="text-tymeslot-500">{dgettext(
            "dashboard_meeting_form",
            "Complete the form to save"
          )}</span>
        <% _other -> %>
          <.icon name="hero-arrow-path-mini" class="w-4 h-4 text-amber-500" />
          <span class="text-amber-500">{dgettext("dashboard_meeting_form", "Unsaved changes")}</span>
      <% end %>
    </div>
    """
  end
end
