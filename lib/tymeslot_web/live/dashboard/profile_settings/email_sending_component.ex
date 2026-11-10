defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSendingComponent do
  @moduledoc """
  Manages the authenticated owner's tested SMTP sending identity.

  Initial settings are loaded by the connected dashboard. Later actions use
  owner-scoped domain APIs and the version held on the server. Credentials
  survive only in a short-lived test task, never in socket assigns or HTML.
  A successful test activates its saved revision only while setup remains on.
  Test submissions and accepted completions report their result through a toast.
  New identities start with the profile name and an editable email-username
  suggestion for the public From address; saved identities stay authoritative.
  Closing setup cancels the pending operation and returns sending to the platform.
  """

  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.Settings
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.ProfileSettings.EmailSending.{ErrorMessages, FormInput, View}
  alias TymeslotWeb.Helpers.FormErrors
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       current_user: nil,
       profile: nil,
       initialized_owner_id: nil,
       settings_loaded: false,
       settings: nil,
       form_values: FormInput.values(nil),
       from_address_edited: false,
       form_errors: %{},
       form_generation: 0,
       security_dropdown_open: false,
       custom_smtp_open: false,
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
      |> assign(Map.take(assigns, [:id, :current_user, :profile]))
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
  def handle_event("toggle_custom_smtp", _params, socket),
    do: with_ready(socket, &toggle_custom_smtp/1, allow_pending: true, allow_closed: true)

  def handle_event("validate_smtp", %{"smtp" => params} = event, socket) do
    with_ready(socket, fn socket ->
      socket =
        if event["_target"] == ["smtp", "from_address"],
          do: assign(socket, :from_address_edited, true),
          else: socket

      attrs = form_attributes(socket, params, event["_target"])

      case EmailSending.change_settings(socket.assigns.current_user, attrs) do
        {:ok, changeset} ->
          errors =
            FormValidationHelpers.clear_target_error(
              socket.assigns.form_errors,
              event["_target"],
              FormInput.fields()
            )

          security_selected? =
            socket.assigns.security_dropdown_open && event["_target"] == ["smtp", "security"]

          # Changing a source field also corrects the public field it derives:
          # the security picker owns the port, and a new username can fill From.
          errors =
            cond do
              event["_target"] == ["smtp", "security"] ->
                Map.delete(errors, :port)

              event["_target"] == ["smtp", "username"] and
                is_nil(socket.assigns.settings) and not socket.assigns.from_address_edited ->
                Map.delete(errors, :from_address)

              true ->
                errors
            end

          socket =
            assign(socket,
              form_values: FormInput.values(changeset),
              form_errors: errors,
              security_dropdown_open: socket.assigns.security_dropdown_open && !security_selected?
            )

          if security_selected?,
            do: push_event(socket, "focus", %{id: "smtp-security-trigger"}),
            else: socket

        {:error, reason} ->
          failed(socket, reason)
      end
    end)
  end

  def handle_event("toggle_smtp_security_dropdown", _params, socket) do
    with_ready(socket, fn socket ->
      assign(socket, :security_dropdown_open, !socket.assigns.security_dropdown_open)
    end)
  end

  def handle_event("close_smtp_security_dropdown", params, socket) do
    with_ready(socket, fn socket ->
      socket = assign(socket, :security_dropdown_open, false)

      if params["key"] == "Escape" or params["selection"] == "true",
        do: push_event(socket, "focus", %{id: "smtp-security-trigger"}),
        else: socket
    end)
  end

  def handle_event("test_and_save_smtp", %{"smtp" => params}, socket) do
    {:noreply, socket} =
      with_ready(socket, fn socket ->
        test_and_save(socket, form_attributes(socket, params, :submit))
      end)

    {:noreply, test_error_toast(socket)}
  end

  def handle_event("request_delete_smtp", _params, socket) do
    with_ready(socket, fn socket ->
      if socket.assigns.settings, do: assign(socket, :confirm_delete, true), else: socket
    end)
  end

  def handle_event("cancel_delete_smtp", _params, socket),
    do: with_ready(socket, &assign(&1, :confirm_delete, false))

  def handle_event("delete_smtp", _params, socket), do: with_ready(socket, &delete_settings/1)

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Opening setup never activates an identity. Closing it cancels tests and
  # returns active sending to the platform through the existing version guard.
  @spec toggle_custom_smtp(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp toggle_custom_smtp(%{assigns: %{custom_smtp_open: false}} = socket) do
    socket
    |> apply_settings(socket.assigns.settings)
    |> assign(:custom_smtp_open, true)
  end

  defp toggle_custom_smtp(socket) do
    socket = cancel_pending(socket)

    # Even a tab that opened an empty or disabled setup may now have an active
    # identity in another tab. Never hide that identity using an old snapshot.
    case EmailSending.get_settings(socket.assigns.current_user) do
      {:ok, %Settings{enabled: true} = current} ->
        if version(socket.assigns.settings) == Settings.version(current),
          do: disable_identity(socket),
          else: failed(socket, :stale)

      {:ok, settings} ->
        # A successful test may have saved this disabled revision while its
        # activation callback is still queued in another tab. Explicitly
        # disable it to invalidate that result before hiding setup.
        socket
        |> apply_settings(settings)
        |> disable_identity()

      {:error, :not_found} ->
        apply_settings(socket, nil)

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  defp with_ready(socket, action, opts \\ []) do
    cond do
      not authorized?(socket) or not socket.assigns.settings_loaded ->
        {:noreply, socket |> cancel_pending() |> failed(:feature_disabled)}

      not socket.assigns.custom_smtp_open and not Keyword.get(opts, :allow_closed, false) ->
        {:noreply, socket}

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

  # Only a fresh identity owns defaults. Remembering whether From was edited
  # needs one boolean, rather than retaining or comparing SMTP credentials.
  @spec form_attributes(Phoenix.LiveView.Socket.t(), term(), term()) :: map()
  defp form_attributes(socket, params, target) do
    attrs = FormInput.attributes(params)

    if is_nil(socket.assigns.settings) and not socket.assigns.from_address_edited and
         (target == ["smtp", "username"] or
            (target == :submit and attrs["from_address"] in [nil, ""])) do
      FormInput.default_from_address(attrs)
    else
      attrs
    end
  end

  defp test_and_save(socket, attrs) do
    user = socket.assigns.current_user

    case EmailSending.change_settings(user, attrs) do
      {:ok, %Changeset{valid?: true} = changeset} ->
        key = {:smtp_test, make_ref()}
        version = version(socket.assigns.settings)

        socket
        |> assign(
          form_values: FormInput.values(changeset),
          form_errors: %{},
          form_generation: socket.assigns.form_generation + 1,
          security_dropdown_open: false,
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

        cond do
          not socket.assigns.custom_smtp_open ->
            {:noreply, socket}

          authorized?(socket) ->
            {:noreply, socket |> test_result(result) |> test_error_toast()}

          true ->
            {:noreply, socket |> failed(:feature_disabled) |> test_error_toast()}
        end

      _stale_or_cancelled ->
        {:noreply, socket}
    end
  end

  # Activate only after accepting the current task's result in this LiveView.
  # Task cancellation or switching off first prevents late activation, even if
  # the SMTP test has already saved a new, disabled identity. The version guard
  # also prevents reactivating a configuration another tab disabled or replaced.
  defp test_result(socket, {:ok, {:ok, %Settings{} = settings}}) do
    socket = apply_settings(socket, settings)

    case EmailSending.enable_settings(socket.assigns.current_user, Settings.version(settings)) do
      {:ok, enabled} ->
        socket
        |> apply_settings(enabled)
        |> assign(
          :notice,
          dgettext(
            "dashboard_email_sending",
            "The SMTP server accepted the test and your sending identity is now active. Acceptance does not confirm inbox delivery."
          )
        )
        |> Flash.put_flash(
          :info,
          dgettext(
            "dashboard_email_sending",
            "SMTP connection healthy. Settings saved and active."
          )
        )

      {:error, reason} ->
        failed(socket, reason)
    end
  end

  defp test_result(socket, {:ok, {:error, %Changeset{} = changeset}}),
    do: invalid_form(socket, changeset)

  defp test_result(socket, {:ok, {:error, reason}}), do: failed(socket, reason)
  defp test_result(socket, _unexpected), do: failed(socket, :unexpected_failure)

  # Reuse only the sanitized inline error. Validation changes and cancelled or
  # superseded tests stay quiet; only submissions and accepted results notify.
  @spec test_error_toast(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp test_error_toast(%{assigns: %{error_message: message}} = socket)
       when is_binary(message),
       do: Flash.put_flash(socket, :error, message)

  defp test_error_toast(socket), do: socket

  defp disable_identity(socket) do
    socket = cancel_pending(socket)

    case EmailSending.disable_settings(
           socket.assigns.current_user,
           Settings.version(socket.assigns.settings)
         ) do
      {:ok, settings} ->
        socket
        |> apply_settings(settings)
        |> assign(
          custom_smtp_open: false,
          notice:
            dgettext("dashboard_email_sending", "Scheduling emails now use the platform sender.")
        )

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
      {:ok, settings} ->
        apply_settings(socket, settings)

      {:error, :not_found} ->
        apply_settings(socket, nil)

      {:error, reason} ->
        assign(socket, error_message: ErrorMessages.message(reason), notice: nil)
    end
  end

  defp apply_settings(socket, settings) do
    assign(socket,
      settings: settings,
      custom_smtp_open:
        match?(%Settings{enabled: true}, settings) or
          (settings != nil and socket.assigns.custom_smtp_open),
      form_values: FormInput.values(settings, Profiles.display_name(socket.assigns.profile)),
      from_address_edited: settings != nil,
      form_errors: %{},
      form_generation: socket.assigns.form_generation + 1,
      security_dropdown_open: false,
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
      form_generation: socket.assigns.form_generation + 1,
      security_dropdown_open: false,
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
