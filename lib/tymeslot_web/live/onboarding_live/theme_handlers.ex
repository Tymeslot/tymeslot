defmodule TymeslotWeb.OnboardingLive.ThemeHandlers do
  @moduledoc """
  Theme and onboarding-choice handlers for the onboarding flow.

  Owns the "choose your theme" feature end to end: switching between the theme
  stories and every theme's look, selecting a booking theme or
  one of its onboarding choices, saving the headline a theme that introduces
  the host asks for, and seeding a random video background once a calendar is
  connected. The stage shows each choice as it is made.
  It also exposes the theme-state helpers the mount pipeline needs, so every
  theme concern lives in one place rather than leaking into the LiveView.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.InputValidation
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @doc """
  Persists the selected booking theme and refreshes the preview state.
  """
  @spec handle_select_theme(String.t(), LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_select_theme(theme_id, socket) do
    profile = socket.assigns[:profile]

    if profile && ThemeInfo.valid_theme_id?(theme_id) do
      case Profiles.update_booking_theme(profile, theme_id) do
        {:ok, updated} ->
          {:noreply, assign_theme_state(socket, updated)}

        {:error, _reason} ->
          {:noreply,
           LiveView.put_flash(
             socket,
             :error,
             dgettext("onboarding_wizard", "Could not update theme. Please try again.")
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @doc """
  Switches the theme step between the stories (`:stories`, "Which of these
  sounds like you?") and the visual picker of every theme's look (`:all`).
  """
  @spec handle_theme_picker(:stories | :all, LiveView.Socket.t()) ::
          {:noreply, LiveView.Socket.t()}
  def handle_theme_picker(picker, socket) when picker in [:stories, :all],
    do: {:noreply, Component.assign(socket, :theme_picker, picker)}

  @doc """
  Applies one of the current theme's onboarding choices (`:onboarding_choices`)
  through its option group, preserving the theme's other customisation (e.g.
  the seeded video background). The group and field come from the theme's
  spec, never from the client.
  """
  @spec handle_select_choice(String.t(), LiveView.Socket.t()) :: {:noreply, LiveView.Socket.t()}
  def handle_select_choice(value, socket) do
    with %{} = profile <- socket.assigns[:profile],
         %{group: group, field: field} <- socket.assigns[:onboarding_choices] do
      profile.id
      |> ThemeCustomizations.apply_option(profile.booking_theme, group, %{
        "field" => field,
        "value" => value
      })
      |> choice_result(socket)
    else
      nil -> {:noreply, socket}
    end
  end

  defp choice_result({:ok, customization}, socket),
    do: {:noreply, Component.assign(socket, :theme_customization, customization)}

  defp choice_result({:error, _reason}, socket) do
    {:noreply,
     LiveView.put_flash(
       socket,
       :error,
       dgettext("onboarding_wizard", "Could not update the colour scheme. Please try again.")
     )}
  end

  @doc """
  Saves the headline typed on the look step, the line a theme that introduces
  the host (`Catalog.shows_intro?/1`) shows under their name, as each change
  arrives (the field is debounced). It goes through the same sanitiser and
  `Profiles.update_intro/2` as the dashboard's intro form, so the cap and the
  normalisation are the profile's own; the bio is left as it is. An empty
  line clears the headline. A refused value keeps the saved one and shows
  why under the field.
  """
  @spec handle_headline_change(map(), LiveView.Socket.t()) :: {:noreply, LiveView.Socket.t()}
  def handle_headline_change(%{"profile_intro" => %{"headline" => headline}}, socket)
      when is_binary(headline) do
    params = %{"headline" => headline}

    with %ProfileSchema{} = profile <- socket.assigns[:profile],
         {:ok, sanitized} <-
           InputValidation.validate_intro(params,
             metadata: DashboardHelpers.get_security_metadata(socket)
           ),
         {:ok, updated} <- Profiles.update_intro(profile, sanitized) do
      {:noreply,
       Component.assign(socket, profile: updated, headline_form: headline_form(updated))}
    else
      nil ->
        {:noreply, socket}

      {:error, %Changeset{} = changeset} ->
        {:noreply, Component.assign(socket, :headline_form, refused_form(changeset))}

      {:error, %{headline: message}} ->
        changeset =
          socket.assigns.profile
          |> ProfileSchema.intro_changeset(%{})
          |> Changeset.add_error(:headline, message)

        {:noreply, Component.assign(socket, :headline_form, refused_form(changeset))}
    end
  end

  def handle_headline_change(_params, socket), do: {:noreply, socket}

  @doc """
  The look step's headline form for a profile (or an empty one before a
  profile exists), named as the dashboard's intro form is.
  """
  @spec headline_form(ProfileSchema.t() | nil) :: Phoenix.HTML.Form.t()
  def headline_form(%ProfileSchema{} = profile),
    do: Component.to_form(ProfileSchema.intro_changeset(profile, %{}), as: :profile_intro)

  def headline_form(nil), do: Component.to_form(%{"headline" => ""}, as: :profile_intro)

  defp refused_form(changeset),
    do: Component.to_form(Map.put(changeset, :action, :update), as: :profile_intro)

  @doc """
  Resolves the initial `{customization, onboarding_choices}` for a profile
  (or the default theme's, with no customisation, before a profile exists)
  for the mount pipeline.
  """
  @spec initial_theme_state(map() | nil) :: {map() | nil, Spec.onboarding_choices()}
  def initial_theme_state(nil),
    do: {nil, ThemeCustomizations.onboarding_choices(Catalog.default_id())}

  def initial_theme_state(profile) do
    %{customization: customization} =
      ThemeCustomizations.initialize_customization(profile.id, profile.booking_theme)

    {customization, ThemeCustomizations.onboarding_choices(profile.booking_theme)}
  end

  @doc """
  Seeds a random video background across every onboarding booking theme once a
  calendar is connected, so the preview shows motion out of the box. No-op
  without a profile or a connected calendar.
  """
  @spec seed_video_backgrounds(map() | nil, list()) :: :ok
  def seed_video_backgrounds(nil, _connected_calendars), do: :ok
  def seed_video_backgrounds(_profile, []), do: :ok

  def seed_video_backgrounds(profile, _connected_calendars) do
    Onboarding.ensure_preview_video_backgrounds(profile, theme_ids())
  end

  defp assign_theme_state(socket, profile) do
    {customization, onboarding_choices} = initial_theme_state(profile)

    socket
    |> Component.assign(:profile, profile)
    |> Component.assign(:theme_customization, customization)
    |> Component.assign(:onboarding_choices, onboarding_choices)
  end

  # Booking-theme ids offered in onboarding, derived from the theme registry.
  defp theme_ids do
    Enum.map(ThemeInfo.theme_options(), fn {_name, id} -> id end)
  end
end
