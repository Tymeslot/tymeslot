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

  With a translation language, a language bar sits above the form, and
  choosing a translation language swaps the form for the translation editor
  (`TymeslotWeb.Dashboard.Languages.TranslatableForm`). A headline or bio
  typed and not yet saved is saved first, so the translator works from the
  current original; when that save is refused the form stays, showing why.

  The form keeps what the organiser has typed when the parent re-renders it
  (after another settings form saves, for instance): it is built from the
  profile only on first render and after its own save.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.InputValidation
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.Languages.TranslatableForm

  @impl Phoenix.LiveComponent
  def update(%{save_original: locale}, socket) do
    case unsaved_params(socket.assigns.form) do
      nil ->
        send(self(), {:editing_locale, locale})
        {:ok, socket}

      params ->
        case save(socket, params) do
          {:ok, socket} ->
            send(self(), {:editing_locale, locale})
            {:ok, socket}

          {:error, socket} ->
            Flash.error(dgettext("dashboard_profile", "Couldn't save your headline and bio"))
            {:ok, socket}
        end
    end
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:editing_locale, fn -> nil end)
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
    {_result, socket} = save(socket, params)
    {:noreply, socket}
  end

  defp save(socket, params) do
    with {:ok, sanitized} <- sanitize(params, socket),
         {:ok, profile} <- Profiles.update_intro(socket.assigns.profile, sanitized) do
      send(self(), {:profile_updated, profile})
      Flash.info(dgettext("dashboard_profile", "Headline and bio saved"))

      {:ok,
       assign(socket,
         profile: profile,
         form: build_form(ProfileSchema.intro_changeset(profile, %{}))
       )}
    else
      {:error, %Changeset{} = changeset} ->
        {:error, assign(socket, :form, build_form(Map.put(changeset, :action, :update)))}

      {:error, field_errors} ->
        Flash.error(dgettext("dashboard_profile", "Couldn't save your headline and bio"))
        changeset = refused(socket.assigns.profile, params, field_errors)

        {:error, assign(socket, :form, build_form(Map.put(changeset, :action, :update)))}
    end
  end

  # What was typed and differs from the saved profile, or nil: a form that
  # was never changed, or was changed back, has nothing to save.
  defp unsaved_params(%{source: %Changeset{changes: changes}, params: params})
       when changes != %{} and params != %{},
       do: params

  defp unsaved_params(_form), do: nil

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="intro-form-container">
      <.section_header level={3} title={dgettext("dashboard_profile", "About You")} class="mb-4" />
      <.live_component
        module={TranslatableForm}
        id={"intro-translations-#{@profile.id}"}
        profile={@profile}
        editing_locale={@editing_locale}
        user_id={@user_id}
        kind={:profile}
        save_original={@myself}
        record={@profile}
        paths={~w(headline bio)}
      >
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
          />
          <.input
            field={@form[:bio]}
            type="textarea"
            rows={6}
            label={dgettext("dashboard_profile", "Bio")}
            placeholder={dgettext("dashboard_profile", "A few sentences about you and how you work.")}
            maxlength={Constraints.profile_bio_max_length()}
            phx-debounce="300"
          />
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
      </.live_component>
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
