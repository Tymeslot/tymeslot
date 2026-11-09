defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSendingComponent do
  @moduledoc """
  Manages the authenticated owner's tested SMTP sending identity.

  Initial settings are loaded by the connected dashboard. Later actions use
  owner-scoped domain APIs and the version held on the server. Credentials
  survive only in a short-lived test task, never in socket assigns or HTML.
  """

  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Settings
  alias Tymeslot.Infrastructure.Tasks
  alias TymeslotWeb.Dashboard.ProfileSettings.EmailSending.{ErrorMessages, FormInput, View}
  alias TymeslotWeb.Helpers.FormErrors
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       current_user: nil,
       initialized_owner_id: nil,
       settings_loaded: false,
       settings: nil,
       form_values: FormInput.values(nil),
       form_errors: %{},
       form_dirty: false,
       form_generation: 0,
       pending: nil,
       confirm_delete: false,
       notice: nil,
       error_message: nil
     )}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> reset_changed_owner(assigns)
      |> assign(Map.take(assigns, [:id, :current_user]))
      |> initialize(assigns)

    {:ok, socket}
  end

  defp reset_changed_owner(socket, assigns) do
    incoming_owner = user_id(Map.get(assigns, :current_user, socket.assigns.current_user))

    if socket.assigns.initialized_owner_id &&
         incoming_owner != socket.assigns.initialized_owner_id do
      socket
      |> cancel_pending()
      |> apply_settings(nil)
      |> assign(initialized_owner_id: nil, settings_loaded: false)
    else
      socket
    end
  end

  # The parent's initial DTO is intentionally consumed once per owner. Flash
  # updates can carry that old snapshot after a local save; reapplying it would
  # resurrect a stale version and overwrite unsaved form edits.
  defp initialize(socket, %{smtp_settings_loaded: true, smtp_settings: settings}) do
    if authorized?(socket) and
         socket.assigns.initialized_owner_id != socket.assigns.current_user.id do
      socket
      |> cancel_pending()
      |> assign(initialized_owner_id: socket.assigns.current_user.id, settings_loaded: true)
      |> apply_settings(settings)
    else
      socket
    end
  end

  defp initialize(socket, _assigns), do: socket

  @impl Phoenix.LiveComponent
  def handle_event("validate_smtp", %{"smtp" => params} = event, socket) do
    with_ready(socket, fn socket ->
      attrs = params |> FormInput.attributes() |> FormInput.align_transport(event["_target"])

      case EmailSending.change_settings(socket.assigns.current_user, attrs) do
        {:ok, changeset} ->
          errors =
            FormValidationHelpers.clear_target_error(
              socket.assigns.form_errors,
              event["_target"],
              FormInput.fields()
            )

          assign(socket,
            form_values: FormInput.values(changeset),
            form_errors: errors,
            form_dirty: FormInput.dirty?(changeset, socket.assigns.settings, attrs)
          )

        {:error, reason} ->
          failed(socket, reason)
      end
    end)
  end

  def handle_event("test_and_save_smtp", %{"smtp" => params}, socket) do
    with_ready(socket, fn socket -> test_and_save(socket, FormInput.attributes(params)) end)
  end

  def handle_event("enable_smtp", _params, socket),
    do: with_ready(socket, &change_activation(&1, :enable))

  def handle_event("disable_smtp", _params, socket),
    do: with_ready(socket, &change_activation(&1, :disable), allow_pending: true)

  def handle_event("request_delete_smtp", _params, socket) do
    with_ready(socket, fn socket ->
      if socket.assigns.settings, do: assign(socket, :confirm_delete, true), else: socket
    end)
  end

  def handle_event("cancel_delete_smtp", _params, socket),
    do: with_ready(socket, &assign(&1, :confirm_delete, false))

  def handle_event("delete_smtp", _params, socket), do: with_ready(socket, &delete_settings/1)

  def handle_event("refresh_smtp", _params, socket), do: with_ready(socket, &reload_settings/1)
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp with_ready(socket, action, opts \\ []) do
    cond do
      not authorized?(socket) or not socket.assigns.settings_loaded ->
        {:noreply, socket |> cancel_pending() |> failed(:feature_disabled)}

      socket.assigns.pending && not Keyword.get(opts, :allow_pending, false) ->
        {:noreply, socket}

      true ->
        {:noreply, action.(socket)}
    end
  end

  defp authorized?(%{assigns: %{current_user: %UserSchema{id: id}}})
       when is_integer(id) and id > 0,
       do: EmailSending.enabled?()

  defp authorized?(_socket), do: false

  defp user_id(%UserSchema{id: id}), do: id
  defp user_id(_user), do: nil

  defp test_and_save(socket, attrs) do
    user = socket.assigns.current_user
    socket = assign(socket, :form_dirty, true)

    case EmailSending.change_settings(user, attrs) do
      {:ok, %Changeset{valid?: true} = changeset} ->
        key = {:smtp_test, make_ref()}
        version = version(socket.assigns.settings)

        socket
        |> assign(
          form_values: FormInput.values(changeset),
          form_errors: %{},
          form_generation: socket.assigns.form_generation + 1,
          pending: %{key: key, owner_id: user.id},
          confirm_delete: false,
          notice: nil,
          error_message: nil
        )
        |> start_async(key, Tasks.with_context(fn -> test_safely(user, attrs, version) end))

      {:ok, changeset} ->
        invalid_form(socket, changeset)

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  # A task crash report must not inspect arguments containing submitted SMTP
  # credentials. The domain returns safe outcomes; unexpected failures become
  # one fixed category before Phoenix observes the task result.
  defp test_safely(user, attrs, version) do
    EmailSending.test_and_save_settings(user, attrs, version)
  rescue
    _error ->
      Logger.warning("SMTP settings test failed unexpectedly")
      {:error, :unexpected_failure}
  catch
    _kind, _reason ->
      Logger.warning("SMTP settings test terminated unexpectedly")
      {:error, :unexpected_failure}
  end

  @impl Phoenix.LiveComponent
  def handle_async({:smtp_test, _reference} = key, result, socket) do
    case socket.assigns.pending do
      %{key: ^key, owner_id: owner_id} when owner_id == socket.assigns.current_user.id ->
        socket = assign(socket, :pending, nil)

        if authorized?(socket),
          do: {:noreply, test_result(socket, result)},
          else: {:noreply, failed(socket, :feature_disabled)}

      _stale_or_cancelled ->
        {:noreply, socket}
    end
  end

  defp test_result(socket, {:ok, {:ok, %Settings{} = settings}}) do
    socket
    |> apply_settings(settings)
    |> assign(
      :notice,
      dgettext(
        "dashboard_email_sending",
        "The SMTP server accepted the test and the settings were saved. Acceptance does not confirm inbox delivery."
      )
    )
  end

  defp test_result(socket, {:ok, {:error, %Changeset{} = changeset}}),
    do: invalid_form(socket, changeset)

  defp test_result(socket, {:ok, {:error, reason}}), do: failed(socket, reason)
  defp test_result(socket, _unexpected), do: failed(socket, :unexpected_failure)

  defp change_activation(%{assigns: %{settings: nil}} = socket, _action), do: socket

  defp change_activation(%{assigns: %{form_dirty: true}} = socket, :enable),
    do: failed(socket, :not_tested)

  defp change_activation(socket, action) do
    socket = cancel_pending(socket)
    user = socket.assigns.current_user
    version = Settings.version(socket.assigns.settings)

    result =
      case action do
        :enable -> EmailSending.enable_settings(user, version)
        :disable -> EmailSending.disable_settings(user, version)
      end

    case result do
      {:ok, settings} ->
        notice =
          case action do
            :enable ->
              dgettext("dashboard_email_sending", "Custom SMTP is enabled for booking emails.")

            :disable ->
              dgettext("dashboard_email_sending", "Booking emails now use the platform sender.")
          end

        socket |> apply_settings(settings) |> assign(:notice, notice)

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  defp delete_settings(
         %{assigns: %{settings: %Settings{} = settings, confirm_delete: true}} = socket
       ) do
    case EmailSending.delete_settings(socket.assigns.current_user, Settings.version(settings)) do
      :ok ->
        socket
        |> apply_settings(nil)
        |> assign(
          :notice,
          dgettext(
            "dashboard_email_sending",
            "The saved SMTP identity and credentials were deleted."
          )
        )

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  defp delete_settings(socket), do: socket

  defp cancel_pending(%{assigns: %{pending: %{key: key}}} = socket) do
    socket |> cancel_async(key) |> assign(:pending, nil)
  end

  defp cancel_pending(socket), do: socket

  defp reload_settings(socket) do
    case EmailSending.get_settings(socket.assigns.current_user) do
      {:ok, settings} -> apply_settings(socket, settings)
      {:error, :not_found} -> apply_settings(socket, nil)
      {:error, reason} -> assign(socket, :error_message, ErrorMessages.message(reason))
    end
  end

  defp apply_settings(socket, settings) do
    assign(socket,
      settings: settings,
      form_values: FormInput.values(settings),
      form_errors: %{},
      form_dirty: false,
      form_generation: socket.assigns.form_generation + 1,
      confirm_delete: false,
      notice: nil,
      error_message: nil
    )
  end

  defp failed(socket, reason) do
    socket =
      if reason in [:stale, :invalid_version, :settings_changed, :not_found],
        do: reload_settings(socket),
        else: socket

    assign(socket, error_message: ErrorMessages.message(reason), notice: nil)
  end

  defp invalid_form(socket, changeset) do
    assign(socket,
      form_values: FormInput.values(changeset),
      form_errors: FormErrors.to_map(changeset),
      form_dirty: true,
      form_generation: socket.assigns.form_generation + 1,
      error_message: ErrorMessages.message(:invalid_settings),
      notice: nil
    )
  end

  defp version(nil), do: :new
  defp version(%Settings{} = settings), do: Settings.version(settings)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns, :visible, authorized?(%{assigns: assigns}) and assigns.settings_loaded)

    View.settings(assigns)
  end
end
