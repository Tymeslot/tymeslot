defmodule TymeslotWeb.Dashboard.ProfileSettings.LegalLinksFormComponent do
  @moduledoc """
  The organiser's legal notice (imprint) and privacy policy links, under
  Profile Settings, for the small footer on their booking pages and on the
  pages guests open from their emails.

  Saved with a button, like the intro form, and validated as it is typed so a
  link that would be refused shows its error before the organiser saves. A
  blank field shows the instance default as its placeholder when the host has
  configured one (`Tymeslot.Profiles.public_legal_links/1`).

  Only the two link fields go through this form's own changeset
  (`Tymeslot.Profiles.ProfileSchema.legal_links_changeset/2`). The form keeps
  what the organiser has typed when the parent re-renders it: it is built from
  the profile only on first render and after its own save.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.InputValidation
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Validation.Constraints

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:defaults, Profiles.public_legal_links(nil))
      |> assign_new(:form, fn ->
        build_form(ProfileSchema.legal_links_changeset(assigns.profile, %{}))
      end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"profile_legal_links" => params}, socket) do
    profile = socket.assigns.profile

    changeset =
      case sanitize(params, socket) do
        {:ok, sanitized} -> ProfileSchema.legal_links_changeset(profile, sanitized)
        {:error, field_errors} -> refused(profile, params, field_errors)
      end

    {:noreply, assign(socket, :form, build_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("save", %{"profile_legal_links" => params}, socket) do
    with {:ok, sanitized} <- sanitize(params, socket),
         {:ok, profile} <- Profiles.update_legal_links(socket.assigns.profile, sanitized) do
      send(self(), {:profile_updated, profile})
      Flash.info(dgettext("dashboard_profile", "Legal links saved"))

      {:noreply,
       assign(socket,
         profile: profile,
         form: build_form(ProfileSchema.legal_links_changeset(profile, %{}))
       )}
    else
      {:error, %Changeset{} = changeset} ->
        Flash.error(dgettext("dashboard_profile", "Couldn't save your legal links"))
        {:noreply, assign(socket, :form, build_form(Map.put(changeset, :action, :update)))}

      {:error, field_errors} ->
        Flash.error(dgettext("dashboard_profile", "Couldn't save your legal links"))
        changeset = refused(socket.assigns.profile, params, field_errors)

        {:noreply, assign(socket, :form, build_form(Map.put(changeset, :action, :update)))}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="legal-links-container">
      <.section_header level={3} title={dgettext("dashboard_profile", "Legal links")} class="mb-4" />
      <.form
        for={@form}
        id="legal-links-form"
        novalidate
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        class="space-y-6"
      >
        <p class="text-sm text-tymeslot-500 font-bold">
          {dgettext(
            "dashboard_profile",
            "Shown in a small footer on your booking pages and on the pages guests open from your emails. Link the pages on your own website."
          )}
        </p>
        <.legal_link_field
          field={@form[:legal_notice_url]}
          label={dgettext("dashboard_profile", "Legal notice (imprint)")}
          default={@defaults.legal_notice_url}
        />
        <.legal_link_field
          field={@form[:privacy_policy_url]}
          label={dgettext("dashboard_profile", "Privacy policy")}
          default={@defaults.privacy_policy_url}
        />
        <div class="flex justify-end">
          <.action_button type="submit" data-testid="save-legal-links">
            {dgettext("dashboard_common", "Save changes")}
          </.action_button>
        </div>
      </.form>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :default, :string, default: nil

  defp legal_link_field(assigns) do
    assigns = assign(assigns, :default_in_use?, default_in_use?(assigns.field, assigns.default))

    ~H"""
    <div>
      <.input
        field={@field}
        type="url"
        label={@label}
        placeholder={@default || "https://"}
        maxlength={Constraints.url_max_length()}
        inputmode="url"
        autocomplete="url"
        phx-debounce="300"
      />
      <p :if={@default_in_use?} class="mt-1 text-sm text-tymeslot-500">
        {dgettext("dashboard_profile", "Instance default in use: %{url}", url: @default)}
      </p>
    </div>
    """
  end

  defp default_in_use?(_field, nil), do: false
  defp default_in_use?(field, _default), do: blank?(field.value)

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp sanitize(params, socket) do
    InputValidation.validate_legal_links(params,
      metadata: DashboardHelpers.get_security_metadata(socket)
    )
  end

  # A field the sanitiser refused cannot be shown again, so it is left out of
  # the changeset and carries only its error; the other field keeps what was
  # typed.
  defp refused(profile, params, field_errors) do
    kept = Map.drop(params, Enum.map(Map.keys(field_errors), &Atom.to_string/1))

    Enum.reduce(field_errors, ProfileSchema.legal_links_changeset(profile, kept), fn {field,
                                                                                      message},
                                                                                     acc ->
      Changeset.add_error(acc, field, message)
    end)
  end

  defp build_form(changeset), do: to_form(changeset, as: :profile_legal_links)
end
