defmodule TymeslotWeb.Dashboard.ProfileSettings.IntroFormComponent do
  @moduledoc """
  The organiser's headline and bio, under Profile Settings: a short line under
  their name and a few paragraphs about them, which a theme that presents the
  organiser shows on the booking page
  (`TymeslotWeb.Themes.Shared.Components.ProfileIntro`; Folio does).

  Saved with a button rather than as each field changes, unlike the display
  name: a bio is written in more than one sitting, and a half-typed paragraph
  should not reach a public page. Each change is validated as it is typed, so
  a cap shows before the organiser saves.

  Both fields go through the plain-text sanitiser before the changeset
  (`Tymeslot.Profiles.InputValidation.validate_intro/2`), on every change as
  well as on save, so a malformed value never reaches the form's own render.

  The form keeps what the organiser has typed when the parent re-renders it
  (after another settings form saves, for instance): it is built from the
  profile only on first render and after its own save.

  With a translation language, the card says how far the headline and bio
  are translated and links to them on the Languages page, where they are
  translated (`TymeslotWeb.Dashboard.Languages.TranslationStatus`).
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.InputValidation
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.Languages.TranslationStatus

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:form, fn ->
        build_form(ProfileSchema.intro_changeset(assigns.profile, %{}))
      end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"profile_intro" => params}, socket) do
    profile = socket.assigns.profile

    changeset =
      case sanitize(params, socket) do
        {:ok, sanitized} -> ProfileSchema.intro_changeset(profile, sanitized)
        {:error, field_errors} -> refused(profile, params, field_errors)
      end

    {:noreply, assign(socket, :form, build_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("save", %{"profile_intro" => params}, socket) do
    with {:ok, sanitized} <- sanitize(params, socket),
         {:ok, profile} <- Profiles.update_intro(socket.assigns.profile, sanitized) do
      send(self(), {:profile_updated, profile})
      Flash.info(dgettext("dashboard_profile", "Headline and bio saved"))

      {:noreply,
       assign(socket,
         profile: profile,
         form: build_form(ProfileSchema.intro_changeset(profile, %{}))
       )}
    else
      {:error, %Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, build_form(Map.put(changeset, :action, :update)))}

      {:error, field_errors} ->
        Flash.error(dgettext("dashboard_profile", "Couldn't save your headline and bio"))
        changeset = refused(socket.assigns.profile, params, field_errors)

        {:noreply, assign(socket, :form, build_form(Map.put(changeset, :action, :update)))}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :translation_status,
        TranslationStatus.build(assigns.profile, :intro, :profile, assigns.profile,
          paths: ~w(headline bio)
        )
      )

    ~H"""
    <div id="intro-form-container">
      <.section_header level={3} title={dgettext("dashboard_profile", "About You")} class="mb-4" />
      <TranslationStatus.strip status={@translation_status} class="mb-6" />
      <.form
        for={@form}
        id="intro-form"
        novalidate
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        class="space-y-6"
      >
        <.input
          field={@form[:headline]}
          type="text"
          label={dgettext("dashboard_profile", "Headline")}
          placeholder={
            dgettext("dashboard_profile", "For example: Career coach for first-time managers")
          }
          maxlength={Constraints.profile_headline_max_length()}
          phx-debounce="300"
        >
          <:label_suffix>
            <TranslationStatus.mark status={@translation_status} path="headline" />
          </:label_suffix>
        </.input>
        <.input
          field={@form[:bio]}
          type="textarea"
          rows={6}
          label={dgettext("dashboard_profile", "Bio")}
          placeholder={dgettext("dashboard_profile", "A few sentences about you and how you work.")}
          maxlength={Constraints.profile_bio_max_length()}
          phx-debounce="300"
        >
          <:label_suffix>
            <TranslationStatus.mark status={@translation_status} path="bio" />
          </:label_suffix>
        </.input>
        <p class="text-sm text-tymeslot-500 font-bold">
          {dgettext(
            "dashboard_profile",
            "Shown on your booking page by themes that introduce you, such as Folio. Leave an empty line between paragraphs."
          )}
        </p>
        <div class="flex justify-end">
          <.action_button type="submit" data-testid="save-intro">
            {dgettext("dashboard_common", "Save changes")}
          </.action_button>
        </div>
      </.form>
    </div>
    """
  end

  defp sanitize(params, socket) do
    InputValidation.validate_intro(params,
      metadata: DashboardHelpers.get_security_metadata(socket)
    )
  end

  # A field the sanitiser refused (malformed bytes, a value that is not text)
  # cannot be shown again, so it is left out of the changeset and carries only
  # its error; the other field keeps what was typed.
  defp refused(profile, params, field_errors) do
    kept = Map.drop(params, Enum.map(Map.keys(field_errors), &Atom.to_string/1))

    Enum.reduce(field_errors, ProfileSchema.intro_changeset(profile, kept), fn {field, message},
                                                                               acc ->
      Changeset.add_error(acc, field, message)
    end)
  end

  defp build_form(changeset), do: to_form(changeset, as: :profile_intro)
end
