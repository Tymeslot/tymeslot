defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Autosave do
  @moduledoc """
  Auto-save orchestration for the meeting-type editor.

  When editing an existing meeting type, every change persists immediately so
  the saved state never depends on an explicit "save" action — closing the
  overlay, navigating away, or dropping the connection all leave the latest
  change already written. `MeetingTypeForm` calls `maybe_run/1` at the tail of
  each mutating event; this module owns the rate-limit guard, the
  serialise-and-persist step, and the resulting `:save_status` transitions.

  Creating a new meeting type is a no-op here — there is no record yet, so the
  explicit "Create Meeting Type" submit still owns persistence.

  ## Save-status atoms

  | Atom          | Indicator copy                              | When set                                                  |
  |---------------|---------------------------------------------|-----------------------------------------------------------|
  | `:saved`      | "All changes saved"                         | Persist succeeded.                                        |
  | `:unsaved`    | "Unsaved changes"                           | Form is valid but in-flight (e.g. invalid-form pre-save). |
  | `:incomplete` | "Complete the form to save"                 | A required companion field is not yet set (video          |
  |               |                                             | provider or target calendar absent, or price not yet      |
  |               |                                             | entered when payment is required). Not a failure — the    |
  |               |                                             | form is legitimately in progress.                         |
  | `:throttled`  | "Too many changes — saving shortly…"        | Rate limit hit. A retry is automatically scheduled.       |
  | `:error`      | "Couldn't save changes"                     | Unexpected persistence failure (changeset or context).    |
  """

  use TymeslotWeb, :html

  require Logger

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.FormHelpers
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
  # :target_calendar_required) and a price_cents-required changeset error when
  # payment has just been enabled are expected incomplete states — the form is
  # legitimately in progress and no alarming error indicator should show.
  #
  # Genuine persistence failures (unexpected changeset errors, unknown context
  # errors) are logged and shown as :error.
  defp apply_result({:ok, updated}, socket) do
    socket
    |> assign(:type, updated)
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

  # Changeset failure where price_cents is the only missing required field:
  # payment was just toggled on but the user hasn't entered a price yet.
  # Treat as :incomplete (guidance) so the "Couldn't save" indicator doesn't
  # fire before they've had a chance to fill in the price.
  defp apply_result({:error, %Ecto.Changeset{} = changeset}, socket)
       when socket.assigns.payment_required == true do
    errors = FormHelpers.format_changeset_errors(changeset)

    if Map.keys(errors) == [:price_cents] do
      assign(socket, :save_status, :incomplete)
    else
      Logger.warning("Autosave changeset failure",
        user_id: socket.assigns.current_user.id,
        meeting_type_id: socket.assigns.type.id
      )

      socket
      |> assign(:form_errors, errors)
      |> assign(:save_status, :error)
    end
  end

  defp apply_result({:error, %Ecto.Changeset{} = changeset}, socket) do
    Logger.warning("Autosave changeset failure",
      user_id: socket.assigns.current_user.id,
      meeting_type_id: socket.assigns.type.id
    )

    socket
    |> assign(:form_errors, FormHelpers.format_changeset_errors(changeset))
    |> assign(:save_status, :error)
  end

  defp apply_result({:error, reason}, socket) do
    Logger.warning("Autosave context error",
      user_id: socket.assigns.current_user.id,
      meeting_type_id: socket.assigns.type.id,
      reason: inspect(reason)
    )

    socket
    |> assign(:form_errors, FormHelpers.format_context_error(reason))
    |> assign(:save_status, :error)
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
          <span class="text-tymeslot-500">All changes saved</span>
        <% :error -> %>
          <.icon name="hero-exclamation-triangle-mini" class="w-4 h-4 text-red-500" />
          <span class="text-red-500">Couldn't save changes</span>
        <% :throttled -> %>
          <.icon name="hero-arrow-path-mini" class="w-4 h-4 text-amber-500 animate-spin" />
          <span class="text-amber-500">Too many changes — saving shortly…</span>
        <% :incomplete -> %>
          <.icon name="hero-information-circle-mini" class="w-4 h-4 text-tymeslot-400" />
          <span class="text-tymeslot-500">Complete the form to save</span>
        <% _other -> %>
          <.icon name="hero-arrow-path-mini" class="w-4 h-4 text-amber-500" />
          <span class="text-amber-500">Unsaved changes</span>
      <% end %>
    </div>
    """
  end
end
