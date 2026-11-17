defmodule TymeslotWeb.Dashboard.ProfileSettings.IntroFormComponent do
  @moduledoc """
  The organiser's headline and bio, under Profile Settings: a short line under
  their name and a few paragraphs about them, which a theme that presents the
  organiser shows on the booking page
  (`TymeslotWeb.Themes.Shared.Components.ProfileIntro`; Folio does).

  Saved when the organiser leaves a field (`TymeslotWeb.Components.Dashboard.Autosave`),
  not at each pause in typing: a bio is written in more than one sitting, and
  a half-typed paragraph should not reach a public page. A value over its cap
  shows its error in place and is not saved; pressing Enter in the headline
  saves as leaving it would.

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
  alias TymeslotWeb.Components.Dashboard.Autosave
  alias TymeslotWeb.Dashboard.Languages.TranslationStatus

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:save_status, fn -> :idle end)
      |> assign_new(:form, fn ->
        build_form(ProfileSchema.intro_changeset(assigns.profile, %{}))
      end)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event(event, %{"profile_intro" => params}, socket)
      when event in ["validate", "save"] do
    profile = socket.assigns.profile

    with {:ok, sanitized} <- sanitize(params, socket),
         %Changeset{valid?: true} = changeset <- ProfileSchema.intro_changeset(profile, sanitized) do
      {:noreply, persist(socket, changeset, sanitized)}
    else
      {:error, field_errors} ->
        {:noreply, show_errors(socket, refused(profile, params, field_errors))}

      %Changeset{} = changeset ->
        {:noreply, show_errors(socket, changeset)}
    end
  end

  defp persist(socket, %Changeset{changes: changes}, _sanitized) when changes == %{} do
    Autosave.clean(socket, "intro-form")
  end

  defp persist(socket, _changeset, sanitized) do
    case Profiles.update_intro(socket.assigns.profile, sanitized) do
      {:ok, profile} ->
        send(self(), {:profile_updated, profile})

        socket
        |> assign(
          profile: profile,
          save_status: :saved,
          form: build_form(ProfileSchema.intro_changeset(profile, %{}))
        )
        |> Autosave.clean("intro-form")

      {:error, %Changeset{} = changeset} ->
        Flash.error(dgettext("dashboard_profile", "Couldn't save your headline and bio"))
        socket |> show_errors(changeset) |> assign(:save_status, :error)
    end
  end

  defp show_errors(socket, changeset) do
    assign(socket,
      form: build_form(Map.put(changeset, :action, :validate)),
      save_status: :idle
    )
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
        phx-hook="UnsavedChanges"
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
          phx-debounce="blur"
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
          phx-debounce="blur"
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
        <Autosave.status id="intro-form-status" status={@save_status} />
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
