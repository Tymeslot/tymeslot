defmodule Tymeslot.ThemeCustomizations.Presets.Fonts do
  @moduledoc """
  The font choices a `font` group may offer. Each id names a pair of CSS
  stacks, `--font-stack-<id>` (body) and `--font-heading-<id>` (headings),
  defined for every id in `assets/css/scheduling/shared/fonts.css`; nothing
  here names a family. Read through `Tymeslot.ThemeCustomizations.Presets`.

  | Id | Body | Headings |
  |---|---|---|
  | `system` | system UI stack | same |
  | `inter` | Inter | Inter |
  | `plex` | IBM Plex Sans | IBM Plex Sans |
  | `classic` | Inter | Source Serif 4 |
  | `literary` | Source Sans 3 | Lora |
  | `editorial` | Inter | Fraunces |
  | `quiet` | system UI stack | system serif stack |

  The dashboard shows the names; those that are words are registered here for
  extraction into `dashboard_appearance` and translated where they are
  shown, while typeface names are not.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  @type preset :: %{required(:name) => String.t()}

  @fonts %{
    "system" => %{name: dgettext_noop("dashboard_appearance", "System")},
    "inter" => %{name: "Inter"},
    "plex" => %{name: "IBM Plex Sans"},
    "classic" => %{name: dgettext_noop("dashboard_appearance", "Classic")},
    "literary" => %{name: dgettext_noop("dashboard_appearance", "Literary")},
    "editorial" => %{name: dgettext_noop("dashboard_appearance", "Editorial")},
    "quiet" => %{name: dgettext_noop("dashboard_appearance", "Quiet")}
  }

  @doc "Every font choice, keyed by id."
  @spec all() :: %{String.t() => preset()}
  def all, do: @fonts
end
