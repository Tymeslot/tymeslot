defmodule Tymeslot.CustomFields.AnswerRenderer do
  @moduledoc """
  Renders a custom-field answer as a human-readable string for display in
  booking confirmations, emails, ICS descriptions, and the host dashboard.

  Always operates on the snapshot definition (string-keyed map) and the
  raw answer value (string / boolean / list / map). Returns a string —
  callers handle HTML escaping at the rendering layer.

  Wording and dates follow the ambient Gettext locale, so a caller renders
  inside the reader's locale: the booking page and the dashboard have it set
  by their locale hooks, and the emails wrap their bodies in
  `Gettext.with_locale/3`. A date answer is written out ("19. Januar 2027")
  through the formatter the emails already use, rather than as the ISO string
  the booker's date input stores. A time answer stays as stored ("09:00"):
  it reads the same in every locale, and an organiser-addressed surface would
  owe the organiser's own clock preference, which a renderer of a bare answer
  does not have.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.Formatting

  @spec render(map(), any()) :: String.t()
  def render(%{"type" => "yes_no"}, true), do: dgettext("common", "Yes")
  def render(%{"type" => "yes_no"}, _other), do: dgettext("common", "No")

  def render(%{"type" => "multi_select", "options" => opts}, values) when is_list(values) do
    opts
    |> Enum.filter(&(&1["key"] in values))
    |> Enum.map_join(", ", & &1["label"])
  end

  def render(%{"type" => "single_select", "options" => opts}, value) do
    case Enum.find(opts, &(&1["key"] == value)) do
      %{"label" => l} -> l
      _other -> to_string(value || "")
    end
  end

  def render(%{"type" => "date"}, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Formatting.format_date(date, Gettext.get_locale(TymeslotWeb.Gettext))
      {:error, _reason} -> value
    end
  end

  # The acknowledgement is stamped in UTC when the booking is submitted, so it
  # says no more than when the booking was made, which every surface showing
  # the answer already gives. Its date alone would also be a day out for a
  # booker within their UTC offset of midnight, and the renderer has no zone
  # to correct it with, so only the tick is shown; the stamp stays stored.
  def render(%{"type" => "note"}, %{"confirmed" => true}) do
    dgettext("common", "✓ Acknowledged")
  end

  def render(_d, nil), do: ""
  def render(_d, value), do: to_string(value)
end
