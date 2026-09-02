defmodule TymeslotWeb.Themes.Shared.BookingText do
  @moduledoc """
  Resolves the booking page's introductory copy: the organiser's own wording
  when they have turned the customisation on, the theme's translated default
  otherwise.

  Every theme with an overview step renders the same three slots, so the
  resolution lives here rather than in each theme. The heading default differs
  by theme (Quill opens with a generic greeting, Rhythm names the organiser)
  and is therefore keyed by theme; the greeting and instruction defaults are
  identical everywhere.

  The defaults live here rather than inline in each theme because the dashboard
  has to show an organiser what a single custom heading replaces in *both*
  themes, which is cross-theme knowledge no individual theme may hold. Themes
  still own the name they introduce themselves by, and pass it in: Rhythm
  substitutes a friendly word when the profile has no name, Quill drops the
  greeting instead.

  The stored wording is a single string, not a per-locale map, matching the
  meeting type names and descriptions rendered directly beneath it on the same
  screen. Turning the customisation on therefore opts these three strings out of
  translation, which is the same trade the rest of the organiser's copy already
  makes.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles.ProfileSchema

  @type theme_key :: :quill | :rhythm

  @doc """
  The page's introductory heading, given the theme whose default applies and the
  name that theme introduces the organiser by.
  """
  @spec heading(ProfileSchema.t() | nil, theme_key(), String.t() | nil) :: String.t()
  def heading(profile, theme_key, name),
    do: custom(profile, :booking_heading) || default_heading(theme_key, name)

  @doc """
  The greeting line. `nil` when there is no name to introduce and no custom
  wording, which drops the line rather than rendering half a sentence.
  """
  @spec greeting(ProfileSchema.t() | nil, String.t() | nil) :: String.t() | nil
  def greeting(profile, name), do: custom(profile, :booking_greeting) || default_greeting(name)

  @doc """
  The line telling the visitor what to do next.
  """
  @spec instruction(ProfileSchema.t() | nil) :: String.t()
  def instruction(profile), do: custom(profile, :booking_instruction) || default_instruction()

  @doc """
  The heading a theme shows when the organiser has not supplied one.
  """
  @spec default_heading(theme_key(), String.t() | nil) :: String.t()
  def default_heading(:rhythm, name),
    do: dgettext("booking", "Schedule with %{name}", name: name)

  def default_heading(_theme_key, _name), do: dgettext("booking", "Let's Connect!")

  @doc """
  The greeting shown when the organiser has not supplied one, or `nil` when
  there is no name to introduce.
  """
  @spec default_greeting(String.t() | nil) :: String.t() | nil
  def default_greeting(nil), do: nil
  def default_greeting(name), do: dgettext("booking", "Hi! I'm %{name}.", name: name)

  @doc """
  The instruction shown when the organiser has not supplied one.
  """
  @spec default_instruction() :: String.t()
  def default_instruction, do: dgettext("booking", "Pick an option below.")

  @doc """
  True when the organiser's own wording is in use.
  """
  @spec customized?(ProfileSchema.t() | nil) :: boolean()
  def customized?(%{booking_text_enabled: true}), do: true
  def customized?(_profile), do: false

  defp custom(%{booking_text_enabled: true} = profile, field), do: Map.get(profile, field)
  defp custom(_profile, _field), do: nil
end
