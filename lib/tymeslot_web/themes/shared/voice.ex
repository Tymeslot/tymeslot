defmodule TymeslotWeb.Themes.Shared.Voice do
  @moduledoc """
  A theme's own wording of the booking lines every theme shares.

  `BookingText`, `ConfirmationText` and `BookingLabels` decide which line a
  page shows; a theme's voice only words it. Each of those modules asks the
  rendering theme's voice first (`line/4`) and keeps the shared wording when
  the theme has no voice or the voice leaves the line alone. A theme names
  its voice with `use TymeslotWeb.Themes.Core.Theme, voice: MyTheme.Voice`.

  A voice implements `c:text/2`: given a key and its bindings, the line in
  the theme's words, or `nil` to keep the shared one. Each line is a literal
  `dpgettext("booking_voice", "<theme key>", "...")` call, so extraction
  finds it and two themes' wordings of one line never share a msgid:

      @impl TymeslotWeb.Themes.Shared.Voice
      def text(:submit, _bindings), do: dpgettext("booking_voice", "studio", "book")

      def text(:heading_named, %{name: name}),
        do: dpgettext("booking_voice", "studio", "book time with %{name}", name: name)

      def text(_key, _bindings), do: nil

  The keys are a closed set, one per line the shared modules produce; asking
  for any other raises `ArgumentError`. A line may use only its key's
  bindings:

  | Key | Bindings | Shared wording |
  |---|---|---|
  | `:heading` | none | "Let's Connect!" (a `:generic` heading style, or no name) |
  | `:heading_named` | `name` | "Schedule with %{name}" (a `:named` heading style) |
  | `:greeting` | `name` | "Hi! I'm %{name}." |
  | `:instruction` | none | "Pick an option below." |
  | `:held_message` | `name` | "%{name}, your request has been sent." |
  | `:held_message_named` | `name`, `organizer_name` | "%{name}, your request to %{organizer_name} has been sent." |
  | `:organizer_fragment` | `name` | "with %{name}" |
  | `:submit` | none | the theme's own label for an ordinary booking |
  | `:submit_request` | none | "Request meeting" |
  | `:submit_request_reschedule` | none | "Request new time" |
  | `:submit_reschedule` | none | "Reschedule Meeting" |

  The organiser's own wording (`booking_text_enabled`) still wins over any
  voice, as it wins over the shared wording.
  """

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @doc "The line for `key` in the theme's words, or `nil` to keep the shared wording."
  @callback text(key :: atom(), bindings :: map()) :: String.t() | nil

  @keys %{
    heading: [],
    heading_named: [:name],
    greeting: [:name],
    instruction: [],
    held_message: [:name],
    held_message_named: [:name, :organizer_name],
    organizer_fragment: [:name],
    submit: [],
    submit_request: [],
    submit_request_reschedule: [],
    submit_reschedule: []
  }

  @doc "Every key a voice may word, sorted."
  @spec keys() :: [atom()]
  def keys, do: @keys |> Map.keys() |> Enum.sort()

  @doc "The bindings the line for `key` receives. Raises for a key outside the set."
  @spec bindings(atom()) :: [atom()]
  def bindings(key), do: Map.fetch!(@keys, check_key!(key))

  @doc "The voice of the theme with catalogue key `theme_key`, or `nil`."
  @spec of(atom() | nil) :: module() | nil
  def of(nil), do: nil

  def of(theme_key) when is_atom(theme_key) do
    case Catalog.key_to_id(theme_key) do
      {:ok, id} -> ThemeInfo.get_voice(id)
      {:error, _unknown} -> nil
    end
  end

  @doc """
  The line for `key`: `voice`'s wording when it has one, else `shared.()`,
  the shared wording, which is only computed when it is needed.
  """
  @spec line(module() | nil, atom(), map(), (-> String.t())) :: String.t()
  def line(voice, key, bindings, shared) when is_function(shared, 0) do
    check_key!(key)

    case voice && voice.text(key, bindings) do
      text when is_binary(text) -> text
      _no_wording -> shared.()
    end
  end

  defp check_key!(key) when is_map_key(@keys, key), do: key

  defp check_key!(key) do
    raise ArgumentError,
          "#{inspect(key)} is not a voice key; the keys are #{inspect(keys())}"
  end
end
