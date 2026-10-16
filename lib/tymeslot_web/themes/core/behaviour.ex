defmodule TymeslotWeb.Themes.Core.Behaviour do
  @moduledoc """
  The contract a booking theme implements.

  A theme owns presentation only: its scheduling LiveView, its metadata for
  the dashboard's theme picker, and the pages it draws around shared bodies
  (meeting management, poll voting, payment return). The booking flow is
  shared (`Shared.SchedulingLive`), and theme facts live in
  `Tymeslot.Themes.Catalog`.

  A theme module implements this through `use TymeslotWeb.Themes.Core.Theme`,
  which generates every callback and dispatches the renders to conventional
  modules under the theme's namespace. Completeness is therefore checked by
  the compiler; there is no runtime check.
  """

  @doc "The theme's scheduling LiveView."
  @callback live_view_module() :: module()

  @doc """
  Presentation metadata for the dashboard's theme picker: `preview_image`, a
  path under `priv/static`, and `description`, translated into the current
  Gettext locale.
  """
  @callback metadata() :: %{preview_image: String.t(), description: String.t()}

  @doc """
  The theme's story: its persona's one-sentence first-person line, translated
  into the current Gettext locale (the `:story` option).
  """
  @callback story() :: String.t()

  @doc """
  The theme's value on each of the seven design axes, in the canonical order
  of `TymeslotWeb.Themes.Core.Axes.names/0` (the `:axes` option).
  """
  @callback axes() :: keyword()

  @doc """
  Renders a meeting management page: `:reschedule`, `:cancel` or
  `:cancel_confirmed`. Any other action raises. The generated default draws
  either the theme's conventional module or, with `:page_shell`,
  `Shared.DefaultPages`.
  """
  @callback render_meeting_action(assigns :: map(), action :: atom()) ::
              Phoenix.LiveView.Rendered.t()

  @doc """
  Renders the public poll voting page. The generated default draws either
  the theme's conventional module or, with `:page_shell`,
  `Shared.DefaultPages`.
  """
  @callback render_poll_action(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  Renders a payment return page, `:processing` or `:cancelled`: the theme's
  shell around `Shared.PaymentReturnComponents`. The generated default draws
  either the theme's conventional module or, with `:page_shell`,
  `Shared.DefaultPages`.
  """
  @callback render_payment_page(assigns :: map(), page :: :processing | :cancelled) ::
              Phoenix.LiveView.Rendered.t()

  @doc """
  Draws the theme in the onboarding wizard. `assigns.variant` is:

    * `:thumbnail`, the theme step's picker tile, with `primary` (the
      scheme's primary colour);
    * `:card`, the live preview card, with `colors`, `slots`, `locale`,
      `highlight_card`, `highlight_slots` and a `header` slot holding the
      shared identity header the card is drawn around.

  Optional: `use TymeslotWeb.Themes.Core.Theme` supplies the generic mock
  (`TymeslotWeb.OnboardingLive.PreviewParts.generic/1`), and the wizard falls
  back to it for a module without this callback.
  """
  @callback onboarding_preview(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  The dashboard panels for the theme's own option groups, keyed by the
  group's module: `%{MyGroup => MyPanel}`. The shared groups
  (`Options.Palette`, `Options.Background`) have built-in panels and need no
  entry; an entry for one replaces its built-in panel for this theme. See
  `TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panels`.
  """
  @callback option_panels() :: %{optional(module()) => module()}

  @doc """
  The module implementing `TymeslotWeb.Themes.Shared.Voice` that words the
  shared booking lines for this theme, or `nil` for the shared wording (the
  `:voice` option of `use TymeslotWeb.Themes.Core.Theme`).
  """
  @callback voice() :: module() | nil

  @optional_callbacks onboarding_preview: 1
end
