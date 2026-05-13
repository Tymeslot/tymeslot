defmodule Tymeslot.CustomFields.AnswerRenderer do
  @moduledoc """
  Renders a custom-field answer as a human-readable string for display in
  booking confirmations, emails, ICS descriptions, and the host dashboard.

  Always operates on the snapshot definition (string-keyed map) and the
  raw answer value (string / boolean / list / map). Returns a string —
  callers handle HTML escaping at the rendering layer.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @spec render(map(), any()) :: String.t()
  def render(%{"type" => "yes_no"}, true), do: gettext("Yes")
  def render(%{"type" => "yes_no"}, _other), do: gettext("No")

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

  def render(%{"type" => "note"}, %{"confirmed" => true, "confirmed_at" => at}) do
    gettext("✓ Acknowledged (%{at})", at: at)
  end

  def render(_d, nil), do: ""
  def render(_d, value), do: to_string(value)
end
