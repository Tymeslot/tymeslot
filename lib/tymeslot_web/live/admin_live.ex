defmodule TymeslotWeb.AdminLive do
  @moduledoc """
  Self-hosted admin control panel. Two tabs:

    * `:settings` — toggle admin-editable runtime settings (registration,
      password auth). These overrides shadow any matching environment
      variable / application config value.
    * `:users` — list users with counts at the top and
      promote/demote admin actions.

  Mounted under `/admin` with the `RequireAdminUiEnabled` + `RequireAdmin`
  plugs on the static path and the `EnsureAdminHook` on_mount on the live
  socket. Returning here from a non-admin context 404s rather than 403s.

  `/admin` resolves to `:settings`; each tab's rendering lives in its own
  component module under `TymeslotWeb.AdminLive.Components.*`. This module
  owns the LiveView callbacks, data loading, and event handling.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.AppSettings
  alias Tymeslot.Auth
  alias Tymeslot.Emails.Branding
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.AdminLive.Components.{Layout, Settings, Users}
  alias TymeslotWeb.AdminLive.Formatters

  require Logger

  # A 300px-wide PNG lands far under this; the cap is a backstop against a
  # client that ignores the hook and posts something else entirely. The sole
  # declaration of the limit: it feeds `allow_upload/3` below, the interpolated
  # "too large" message, and (via `Settings.email_logo_row/1`'s `max_bytes`
  # attr) the client-side guard in the upload hook.
  @logo_max_bytes 2_000_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, dgettext("dashboard_admin", "Admin"))
     |> assign(:profile, nil)
     |> assign(:pending_action, nil)
     |> assign(:role_change_submitting, false)
     |> assign(:accent_draft, nil)
     |> assign(:max_logo_bytes, @logo_max_bytes)
     |> allow_upload(:email_logo,
       accept: ~w(.png),
       max_entries: 1,
       max_file_size: @logo_max_bytes,
       auto_upload: true,
       progress: &handle_logo_progress/3
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, load_data(socket)}
  end

  # --- Settings tab events ---

  @impl Phoenix.LiveView
  def handle_event("set_setting", %{"key" => key, "state" => state}, socket) do
    with {:ok, atom_key} <- parse_setting_key(key),
         {:ok, parsed} <- parse_setting_value(state) do
      handle_setting_update(socket, atom_key, parsed, state)
    else
      _other ->
        {:noreply,
         put_flash(socket, :error, dgettext("dashboard_admin", "Could not update setting."))}
    end
  end

  # Submit handler used by score and email inputs that don't fit the
  # two-state Enabled/Disabled toggle pattern. Score inputs autosave on blur
  # via `phx-change`, so the handler short-circuits when the value is
  # unchanged to avoid spurious flashes on tab-through.
  def handle_event("save_setting", %{"key" => key} = params, socket) do
    raw_value = Map.get(params, "value", "")

    with {:ok, atom_key} <- parse_setting_key(key),
         {:ok, value} <- parse_typed_value(atom_key, raw_value),
         :changed <- detect_change(socket, atom_key, value) do
      handle_typed_setting_update(socket, atom_key, value)
    else
      # Submitting the value already in effect (e.g. a built-in default the
      # field was pre-populated with) is a legitimate no-op, not an error -
      # acknowledge it with the same saved pulse a real write gets so the
      # button doesn't look like it did nothing.
      :unchanged ->
        {:noreply, push_event(socket, "ts:setting-saved", %{key: key})}

      :invalid ->
        {:noreply, put_flash(socket, :error, value_invalid_message(key))}

      _other ->
        {:noreply,
         put_flash(socket, :error, dgettext("dashboard_admin", "Could not update setting."))}
    end
  end

  # The accent swatch is preview-only: picking a colour never writes to
  # `AppSettings` directly. It only updates `accent_draft`, which the hex
  # field mirrors, so the hex form's submit remains the single writer for
  # `email_brand_accent` - see the comment on `Settings.brand_accent_row/1`.
  def handle_event("preview_accent", %{"value" => value}, socket) do
    case Branding.normalise_accent(value) do
      nil -> {:noreply, socket}
      hex -> {:noreply, assign(socket, :accent_draft, hex)}
    end
  end

  # --- Email branding: logo upload ---

  # Required by the upload form's phx-change. The work happens in
  # `handle_logo_progress/3` once the auto-upload completes; this only needs
  # to re-render so validation errors reach the page.
  def handle_event("validate_email_logo", _params, socket), do: {:noreply, socket}

  # Pushed by the upload hook when the browser cannot decode the file the
  # admin picked — a corrupt PNG, or an SVG that references resources the
  # canvas render cannot resolve. Nothing was uploaded, so this only reports.
  def handle_event("email_logo_conversion_failed", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       dgettext("dashboard_admin", "That image could not be read. Try a PNG or JPEG.")
     )}
  end

  # Pushed by the upload hook when the picked source file is too large to be
  # worth rasterising at all. Rejected before `readAsDataURL`, so nothing was
  # read or uploaded.
  def handle_event("email_logo_too_large", _params, socket) do
    {:noreply, put_flash(socket, :error, logo_too_large_message())}
  end

  def handle_event("remove_email_logo", _params, socket) do
    case Branding.remove_logo() do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("dashboard_admin", "Email logo removed."))
         |> load_data()}

      {:error, reason} ->
        Logger.warning("Failed to remove email logo", reason: inspect(reason))

        {:noreply,
         put_flash(socket, :error, dgettext("dashboard_admin", "Could not remove the logo."))}
    end
  end

  # --- Users tab events: role-change flow ---

  def handle_event("request_promote", params, socket),
    do: open_pending_action(:promote, params, socket)

  def handle_event("request_demote", params, socket),
    do: open_pending_action(:demote, params, socket)

  def handle_event("cancel_pending_action", _params, socket) do
    {:noreply, clear_pending_action(socket)}
  end

  def handle_event("promote_user", %{"id" => id}, socket) do
    with_user_id(id, socket, &handle_promote(&1, assign(socket, :role_change_submitting, true)))
  end

  def handle_event("demote_user", %{"id" => id}, socket) do
    with_user_id(id, socket, &handle_demote(&1, assign(socket, :role_change_submitting, true)))
  end

  # --- Email branding helpers ---

  # Auto-upload progress callback. Consumes the entry only once it is fully
  # uploaded; `consume_uploaded_entry/3` also releases the temporary file, so
  # a rejected PNG leaves nothing behind.
  defp handle_logo_progress(:email_logo, entry, socket) do
    if entry.done? do
      {:noreply, store_uploaded_logo(socket, entry)}
    else
      {:noreply, socket}
    end
  end

  defp store_uploaded_logo(socket, entry) do
    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Branding.store_logo(path)}
      end)

    case result do
      {:ok, _relative} ->
        socket
        |> put_flash(:info, dgettext("dashboard_admin", "Email logo updated."))
        |> load_data()

      {:error, :not_a_png} ->
        put_flash(
          socket,
          :error,
          dgettext("dashboard_admin", "That file is not a valid image and was not saved.")
        )

      {:error, reason} ->
        Logger.warning("Failed to store email logo", reason: inspect(reason))
        put_flash(socket, :error, dgettext("dashboard_admin", "Could not save the logo."))
    end
  end

  defp handle_setting_update(socket, atom_key, parsed, state) do
    case AppSettings.update(%{atom_key => parsed}) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> put_flash(:info, setting_change_message(atom_key, state))
         |> load_data()}

      {:error, :would_lock_out} ->
        {:noreply, put_flash(socket, :error, lock_out_message(atom_key, parsed))}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, dgettext("dashboard_admin", "Could not update setting."))}
    end
  end

  # Picks the lock-reason copy that matches the specific key/value the admin
  # tried to set. Falls back to a generic message if no tailored clause
  # exists, so an SSO toggle rejection never shows a password-auth message.
  defp lock_out_message(key, value) do
    Formatters.lock_reason(key, value) ||
      dgettext("dashboard_admin", "That change would lock everyone out and was not applied.")
  end

  # --- Settings helpers ---

  defp parse_setting_key(key) do
    AppSettings.keys()
    |> Map.new(fn k -> {Atom.to_string(k), k} end)
    |> Map.fetch(key)
  end

  defp parse_setting_value("true"), do: {:ok, true}
  defp parse_setting_value("false"), do: {:ok, false}
  defp parse_setting_value(_other), do: :error

  defp setting_change_message(key, "true"),
    do: dgettext("dashboard_admin", "%{name} enabled.", name: Formatters.humanise(key))

  defp setting_change_message(key, "false"),
    do: dgettext("dashboard_admin", "%{name} disabled.", name: Formatters.humanise(key))

  defp handle_typed_setting_update(socket, key, value) do
    case AppSettings.update(%{key => value}) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext("dashboard_admin", "%{name} updated.", name: Formatters.humanise(key))
         )
         |> push_event("ts:setting-saved", %{key: Atom.to_string(key)})
         |> load_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset, key))}

      {:error, _other} ->
        {:noreply,
         put_flash(socket, :error, dgettext("dashboard_admin", "Could not update setting."))}
    end
  end

  defp parse_typed_value(key, raw) do
    case Formatters.kind(key) do
      :score -> parse_score(raw)
      :email -> parse_email(raw)
      :colour -> parse_colour(raw)
      :text -> parse_text(raw)
      kind when kind in [:boolean, :logo] -> :invalid
    end
  end

  defp detect_change(socket, key, value) do
    case get_in(socket.assigns, [:effective_values, key]) do
      %{value: ^value} -> :unchanged
      _other -> :changed
    end
  end

  # Empty string clears the override. Trim to avoid whitespace-only inputs
  # reaching the schema.
  defp parse_email(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_email(_other), do: :invalid

  defp parse_score(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {score, ""} when score >= 0.0 and score <= 1.0 -> {:ok, score}
      _other -> :invalid
    end
  end

  defp parse_score(_other), do: :invalid

  # Normalised here as well as in the changeset so `detect_change/3` compares
  # like with like: the native colour picker submits "#14B8A6" where the row
  # holds "#14b8a6", and an unnormalised comparison would read as a change and
  # flash "updated" on every tab-through.
  defp parse_colour(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> normalised_colour(trimmed)
    end
  end

  defp parse_colour(_other), do: :invalid

  defp normalised_colour(value) do
    case Branding.normalise_accent(value) do
      nil -> :invalid
      hex -> {:ok, hex}
    end
  end

  defp parse_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_text(_other), do: :invalid

  defp value_invalid_message(key) do
    case parse_setting_key(key) do
      {:ok, atom_key} ->
        case Formatters.kind(atom_key) do
          :score -> dgettext("dashboard_admin", "Enter a number between 0.0 and 1.0.")
          :email -> dgettext("dashboard_admin", "Enter a valid email address.")
          :colour -> dgettext("dashboard_admin", "Enter a hex colour such as #14b8a6.")
          :text -> dgettext("dashboard_admin", "That value is too long.")
          _other -> dgettext("dashboard_admin", "Could not update setting.")
        end

      _other ->
        dgettext("dashboard_admin", "Could not update setting.")
    end
  end

  # Changeset errors from validate_format ("has invalid format") and
  # validate_number ("must be greater than or equal to 0.0", etc.) are
  # accurate but not friendly. Map them to the same human messages the inline
  # parser uses so admins see one consistent phrasing whichever guard catches
  # the bad input.
  defp changeset_message(%Ecto.Changeset{errors: errors}, key) do
    case Keyword.get(errors, key) do
      {_message, _meta} -> value_invalid_message(Atom.to_string(key))
      nil -> dgettext("dashboard_admin", "Could not update setting.")
    end
  end

  # --- Role-change helpers ---

  defp open_pending_action(kind, %{"id" => id, "email" => email}, socket) do
    case parse_user_id(id) do
      {:ok, user_id} ->
        {:noreply, assign(socket, :pending_action, %{kind: kind, id: user_id, email: email})}

      :error ->
        {:noreply, put_flash(socket, :error, dgettext("dashboard_admin", "Invalid user id."))}
    end
  end

  defp open_pending_action(_kind, _params, socket) do
    {:noreply, put_flash(socket, :error, dgettext("dashboard_admin", "Invalid request."))}
  end

  defp with_user_id(id, socket, fun) do
    case parse_user_id(id) do
      {:ok, user_id} ->
        fun.(user_id)

      :error ->
        {:noreply, put_flash(socket, :error, dgettext("dashboard_admin", "Invalid user id."))}
    end
  end

  defp parse_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {user_id, ""} when user_id > 0 -> {:ok, user_id}
      _other -> :error
    end
  end

  defp parse_user_id(_id), do: :error

  defp handle_promote(user_id, socket) do
    case Auth.promote_admin(socket.assigns.current_user, user_id) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:info, dgettext("dashboard_admin", "User promoted to admin."))
         |> push_patch(to: ~p"/admin/users")}

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:error, role_change_error_message(:promote, reason))}
    end
  end

  defp handle_demote(user_id, socket) do
    self_demote? = user_id == socket.assigns.current_user.id

    case Auth.demote_admin(socket.assigns.current_user, user_id) do
      {:ok, _user} when self_demote? ->
        # Self-demote: force a full reload of /dashboard so the new request
        # runs through the plug pipeline with the now-demoted user, dropping
        # the admin menu entry and blocking /admin reentry.
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:info, dgettext("dashboard_admin", "You have been demoted from admin."))
         |> redirect(to: ~p"/dashboard")}

      {:ok, _user} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:info, dgettext("dashboard_admin", "User demoted from admin."))
         |> push_patch(to: ~p"/admin/users")}

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_pending_action()
         |> put_flash(:error, role_change_error_message(:demote, reason))}
    end
  end

  defp role_change_error_message(_action, :not_found),
    do: dgettext("dashboard_admin", "User not found.")

  defp role_change_error_message(_action, :admin_ui_disabled),
    do: dgettext("dashboard_admin", "Admin UI is disabled.")

  defp role_change_error_message(:demote, :last_admin),
    do: dgettext("dashboard_admin", "Cannot demote the last admin. Promote someone else first.")

  defp role_change_error_message(:promote, %Ecto.Changeset{}),
    do: dgettext("dashboard_admin", "Could not promote user.")

  defp role_change_error_message(:demote, %Ecto.Changeset{}),
    do: dgettext("dashboard_admin", "Could not demote user.")

  defp clear_pending_action(socket) do
    socket
    |> assign(:pending_action, nil)
    |> assign(:role_change_submitting, false)
  end

  # --- Data loading ---

  defp load_data(socket) do
    user = socket.assigns.current_user
    profile = Profiles.get_profile(user.id) || %ProfileSchema{user_id: user.id}
    effective_values = AppSettings.effective_values()
    accent = Map.fetch!(effective_values, :email_brand_accent).value

    socket
    |> assign(:profile, profile)
    |> assign(:effective_values, effective_values)
    |> assign(:email_logo_url, Branding.logo_url())
    |> assign(:stock_accent, Branding.stock_accent())
    |> assign(:accent_preview, Branding.accent_preview(accent))
    |> assign(:accent_draft, nil)
    |> assign(:users, Auth.list_users())
    |> assign(:user_count, Auth.count_users())
    |> assign(:admin_count, Auth.count_admins())
  end

  # Config-level errors (`:too_many_files`) come from `upload_errors/1`; a
  # rejected entry (`:too_large`, `:not_accepted`, or a disk-level
  # `{:writer_failure, reason}`) only shows up per-entry via `upload_errors/2`
  # - without iterating entries those never reach the admin at all.
  defp logo_error_messages(upload) do
    config_errors = upload |> upload_errors() |> Enum.map(&upload_error_message/1)

    entry_errors =
      upload.entries
      |> Enum.flat_map(&upload_errors(upload, &1))
      |> Enum.map(&upload_error_message/1)

    config_errors ++ entry_errors
  end

  defp upload_error_message(:too_large), do: logo_too_large_message()

  defp upload_error_message(:not_accepted),
    do: dgettext("dashboard_admin", "That file type is not supported.")

  defp upload_error_message(:too_many_files),
    do: dgettext("dashboard_admin", "Upload one logo at a time.")

  defp upload_error_message(_other),
    do: dgettext("dashboard_admin", "The logo could not be uploaded.")

  # Shared by the framework-level `:too_large` upload error and the hook's
  # client-side pre-check, so both phrase the limit identically and neither
  # hardcodes it - `@logo_max_bytes` is the only place the number lives.
  defp logo_too_large_message do
    dgettext(
      "dashboard_admin",
      "That image is too large. Pick one under %{limit}.",
      limit: logo_max_size_label()
    )
  end

  defp logo_max_size_label, do: "#{div(@logo_max_bytes, 1_000_000)} MB"

  # --- Render: each tab is a thin shell around its component module ---

  @impl Phoenix.LiveView
  def render(%{live_action: :settings} = assigns) do
    ~H"""
    <Layout.admin_layout
      live_action={@live_action}
      current_user={@current_user}
      profile={@profile}
    >
      <Settings.settings_tab
        effective_values={@effective_values}
        email_logo_url={@email_logo_url}
        upload={@uploads.email_logo}
        logo_errors={logo_error_messages(@uploads.email_logo)}
        stock_accent={@stock_accent}
        accent_preview={@accent_preview}
        accent_draft={@accent_draft}
        max_logo_bytes={@max_logo_bytes}
      />
    </Layout.admin_layout>
    """
  end

  def render(%{live_action: :users} = assigns) do
    ~H"""
    <Layout.admin_layout
      live_action={@live_action}
      current_user={@current_user}
      profile={@profile}
    >
      <Users.users_tab
        users={@users}
        current_user={@current_user}
        user_count={@user_count}
        admin_count={@admin_count}
        pending_action={@pending_action}
        role_change_submitting={@role_change_submitting}
      />
    </Layout.admin_layout>
    """
  end
end
