defmodule Tymeslot.ThemeCustomizations.Presets.Accents do
  @moduledoc """
  The accent presets: one colour each, the light-mode accent of a page whose
  `accent` group lists it. `Options.Accent` fits it as text on the card of
  each colour set, so on a dark card it lifts as far as it needs to (the
  `graphite` "no colour" choice becomes a light grey). Read through
  `Tymeslot.ThemeCustomizations.Presets`.

  The dashboard shows the names, so they are registered here for extraction
  into `dashboard_appearance` and translated where they are shown; the brand
  name is not.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  @type preset :: %{required(:name) => String.t(), required(:color) => String.t()}

  @accents %{
    "tymeslot" => %{name: "Tymeslot", color: "#0891b2"},
    "cobalt" => %{name: dgettext_noop("dashboard_appearance", "Cobalt"), color: "#2563eb"},
    "indigo" => %{name: dgettext_noop("dashboard_appearance", "Indigo"), color: "#4f46e5"},
    "violet" => %{name: dgettext_noop("dashboard_appearance", "Violet"), color: "#7c3aed"},
    "rose" => %{name: dgettext_noop("dashboard_appearance", "Rose"), color: "#e11d48"},
    "ember" => %{name: dgettext_noop("dashboard_appearance", "Ember"), color: "#ea580c"},
    "emerald" => %{name: dgettext_noop("dashboard_appearance", "Emerald"), color: "#059669"},
    "teal" => %{name: dgettext_noop("dashboard_appearance", "Teal"), color: "#0d9488"},
    "graphite" => %{name: dgettext_noop("dashboard_appearance", "Graphite"), color: "#374151"}
  }

  @doc "Every accent, keyed by id."
  @spec all() :: %{String.t() => preset()}
  def all, do: @accents
end
