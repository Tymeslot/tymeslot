defmodule TymeslotWeb.Themes.Shared.BookingText do
  @moduledoc """
  Resolves the booking page's introductory copy: the organiser's own wording
  when they have turned the customisation on, the theme's translated default
  otherwise.

  Every theme with an overview step renders the same three slots, so the
  resolution lives here rather than in each theme. The heading default follows
  the theme's `heading_style` catalogue fact (`:generic` for a greeting,
  `:named` to name the organiser), so a new theme picks a style in the
  catalogue rather than a clause here; the greeting and instruction defaults are
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

  It also owns the meeting-length label every step shows, `duration_label/1`, so
  the themes cannot disagree about which duration wins, and a paid meeting
  type's price, `price_label/3`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Components.PaymentHelpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @type theme_key :: Catalog.theme_key()

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

  A theme that introduces the organiser by name falls back to the generic
  heading when there is no name, rather than to a filler word.
  """
  @spec default_heading(theme_key(), String.t() | nil) :: String.t()
  def default_heading(theme_key, name) do
    case {heading_style(theme_key), name} do
      {:named, name} when is_binary(name) ->
        dgettext("booking", "Schedule with %{name}", name: name)

      _generic_or_nameless ->
        dgettext("booking", "Let's Connect!")
    end
  end

  # A key the catalogue does not know takes the default theme's style.
  defp heading_style(theme_key) do
    case Map.fetch(Catalog.all(), theme_key) do
      {:ok, %{heading_style: style}} -> style
      :error -> Catalog.default().heading_style
    end
  end

  @doc """
  The greeting shown when the organiser has not supplied one, or `nil` when
  there is no name to introduce.
  """
  @spec default_greeting(String.t() | nil) :: String.t() | nil
  def default_greeting(nil), do: nil
  def default_greeting(name), do: dgettext("booking", "Hi! I'm %{name}.", name: name)

  @doc """
  A greeting to start the organiser off with when they switch the customisation
  on, which unlike `default_greeting/1` is never `nil`.

  Turning the customisation on requires all three lines to be filled, so a
  profile with no name still needs something to seed the field with. The public
  page keeps dropping the line in that case; this is only ever a starting point
  in the dashboard.
  """
  @spec seed_greeting(String.t() | nil) :: String.t()
  def seed_greeting(nil), do: dgettext("booking", "Hi there!")
  def seed_greeting(name), do: default_greeting(name)

  @doc """
  The instruction shown when the organiser has not supplied one.
  """
  @spec default_instruction() :: String.t()
  def default_instruction, do: dgettext("booking", "Pick an option below.")

  defp custom(%{booking_text_enabled: true} = profile, field), do: Map.get(profile, field)
  defp custom(_profile, _field), do: nil

  @doc """
  The meeting's length as a step shows it: the meeting type's own duration
  when the page has resolved one, otherwise the duration selected in the URL
  (`:duration`, e.g. `"30-minutes"`).

  Takes a map with `:meeting_type` and `:duration`, so a step component can
  pass its assigns straight through; a component whose selected duration lives
  under another key builds the map itself.
  """
  @spec duration_label(map()) :: String.t()
  def duration_label(%{meeting_type: %{duration_minutes: minutes}}),
    do: LocalizationHelpers.format_duration(minutes)

  def duration_label(assigns),
    do: LocalizationHelpers.format_duration(Map.get(assigns, :duration))

  @doc """
  A paid meeting type's price in the organiser's currency (`@host_currency`,
  which the page holds from mount), written the way the guest's `locale`
  writes amounts ("€45.00", "45,00 €"), or `nil` for a free type, for a paid
  one without a price, and when the currency is unknown. A demo persona's
  meeting type is a plain map without the fields, and is `nil` too.
  """
  @spec price_label(map() | nil, String.t() | nil, String.t()) :: String.t() | nil
  def price_label(%{payment_required: true, price_cents: cents}, currency, locale)
      when is_integer(cents) and cents > 0 and is_binary(currency),
      do: PaymentHelpers.format_amount(cents, currency, locale)

  def price_label(_meeting_type, _currency, _locale), do: nil
end
