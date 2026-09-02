defmodule TymeslotWeb.Dashboard.ThemeSettings.BookingTextForm do
  @moduledoc """
  Dashboard form for the booking page's introductory heading, greeting and
  instruction.

  The wording is stored on the profile and applies to every theme, so this form
  spells out what a single heading replaces in each of them: the two themes open
  differently by default, and an organiser editing one field needs to see both
  sentences it displaces.

  Turning the customisation off keeps the stored wording, so the form reflects
  the last thing the organiser wrote rather than clearing itself.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.HTML.Form
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Themes.Shared.BookingText

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:preview_token, fn -> System.system_time() end)
      |> assign_form(ProfileSchema.booking_text_changeset(assigns.profile, %{}))

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class="mt-16">
      <.section_header
        icon="hero-chat-bubble-bottom-center-text"
        title={dgettext("dashboard_appearance", "Booking Page Text")}
      />

      <div class="mb-10 max-w-2xl">
        <p class="text-xl text-tymeslot-500 font-medium leading-relaxed">
          {dgettext(
            "dashboard_appearance",
            "Replace the wording that introduces you at the top of your booking page. Applies to every theme."
          )}
        </p>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-10">
        <.form
          for={@form}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
          class="card-glass p-8 space-y-6"
        >
          <.input
            field={@form[:booking_text_enabled]}
            type="checkbox"
            label={dgettext("dashboard_appearance", "Use my own wording")}
          >
            <:description>
              {dgettext(
                "dashboard_appearance",
                "Turn this off to go back to the built-in text, which is translated into every language Tymeslot supports. Your wording is kept either way."
              )}
            </:description>
          </.input>

          <div :if={enabled?(@form)} class="space-y-6">
            <.input
              field={@form[:booking_heading]}
              type="text"
              required
              maxlength={Constraints.booking_heading_max_length()}
              label={dgettext("dashboard_appearance", "Heading")}
              placeholder={BookingText.default_heading(current_theme_key(@profile), name(@profile))}
            />

            <.input
              field={@form[:booking_greeting]}
              type="text"
              required
              maxlength={Constraints.booking_welcome_line_max_length()}
              label={dgettext("dashboard_appearance", "Greeting")}
              placeholder={BookingText.default_greeting(name(@profile))}
            />

            <.input
              field={@form[:booking_instruction]}
              type="text"
              required
              maxlength={Constraints.booking_welcome_line_max_length()}
              label={dgettext("dashboard_appearance", "Instruction")}
              placeholder={BookingText.default_instruction()}
            />

            <.info_box variant={:info}>
              <p class="font-bold mb-2">
                {dgettext("dashboard_appearance", "Your heading replaces:")}
              </p>
              <ul class="space-y-1">
                <li :for={{theme_name, theme_key} <- heading_defaults()}>
                  <span class="font-semibold">{theme_name}</span>
                  <span class="text-tymeslot-500">
                    &ldquo;{BookingText.default_heading(theme_key, name(@profile))}&rdquo;
                  </span>
                  <span :if={theme_key == current_theme_key(@profile)} class="text-turquoise-600">
                    {dgettext("dashboard_appearance", "(your current theme)")}
                  </span>
                </li>
              </ul>
            </.info_box>

            <p class="text-token-sm text-tymeslot-500">
              {dgettext(
                "dashboard_appearance",
                "Your own wording is shown to everyone, in whatever language they pick. Only the built-in text is translated."
              )}
            </p>
          </div>

          <div class="flex justify-end pt-2">
            <.action_button type="submit" variant={:primary}>
              {dgettext("dashboard_appearance", "Save Text")}
            </.action_button>
          </div>
        </.form>

        <div class="space-y-3">
          <p class="text-token-sm font-bold text-tymeslot-600 uppercase tracking-wider">
            {dgettext("dashboard_appearance", "Live Preview")}
          </p>
          <%= if preview_url = preview_url(@profile, @preview_token) do %>
            <iframe
              src={preview_url}
              title={dgettext("dashboard_appearance", "Booking page preview")}
              class="w-full h-[600px] rounded-token-2xl border-2 border-tymeslot-100 bg-tymeslot-50"
              loading="lazy"
            ></iframe>
            <p class="text-token-sm text-tymeslot-500">
              {dgettext("dashboard_appearance", "The preview updates when you save.")}
            </p>
          <% else %>
            <.empty_state
              message={dgettext("dashboard_appearance", "No preview yet")}
              secondary_message={
                dgettext(
                  "dashboard_appearance",
                  "Pick a username for your booking page to see it here."
                )
              }
            >
              <:icon>
                <.icon name="hero-eye-slash" class="w-8 h-8 text-tymeslot-400" />
              </:icon>
            </.empty_state>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"profile_schema" => params}, socket) do
    changeset =
      socket.assigns.profile
      |> ProfileSchema.booking_text_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"profile_schema" => params}, socket) do
    case Profiles.update_booking_text(socket.assigns.profile, params) do
      {:ok, profile} ->
        send(self(), {:profile_updated, profile})

        {:noreply,
         socket
         |> assign(:profile, profile)
         # A new token reloads the iframe, which renders the saved wording; the
         # preview reads persisted state, not the form.
         |> assign(:preview_token, System.system_time())
         |> assign_form(ProfileSchema.booking_text_changeset(profile, %{}))
         |> Flash.put_flash(
           :info,
           dgettext("dashboard_appearance", "Booking page text updated")
         )}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

  defp enabled?(form), do: Form.normalize_value("checkbox", form[:booking_text_enabled].value)

  defp name(profile), do: Profiles.display_name(profile)

  defp current_theme_key(profile) do
    case Catalog.id_to_key(profile.booking_theme) do
      {:ok, key} -> key
      {:error, _reason} -> Catalog.default_key()
    end
  end

  # One entry per selectable theme so the organiser sees every sentence a custom
  # heading displaces, not only the one their current theme happens to show.
  # Ordered by id so the list does not reshuffle between renders.
  defp heading_defaults do
    Catalog.active()
    |> Enum.sort_by(fn {_key, facts} -> facts.id end)
    |> Enum.map(fn {key, facts} -> {facts.name, key} end)
  end

  defp preview_url(%{username: username, user_id: user_id}, token)
       when is_binary(username) and is_integer(user_id) do
    PreviewMode.owner_path(username, user_id) <> "&t=#{token}"
  end

  defp preview_url(_profile, _token), do: nil
end
