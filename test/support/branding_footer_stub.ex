defmodule TymeslotWeb.Test.BrandingFooterStub do
  @moduledoc """
  Test-only stand-in for the SaaS branding banner.

  The real banner lives in SaaS (`TymeslotSaasWeb.Components.BrandingOverlay`) and
  is injected into the booking page via the Core `:theme_extensions` config. Core
  tests can't load the SaaS branding CSS, so this stub reproduces just enough of
  the banner — a `.branding-footer` element placed in `grid-row: 2` of the theme
  grid at the banner's real-ish height — to exercise Core's footer-fit CSS rule
  (`.main-gradient.theme-grid:has(.branding-footer) .content-area`), which keeps
  the banner inside the viewport instead of pushing it past `100vh`.

  Wire it in for a single test with:

      Application.put_env(:tymeslot, :theme_extensions,
        [{TymeslotWeb.Test.BrandingFooterStub, :banner}])

  and reset it on exit.
  """
  use Phoenix.Component

  @spec banner(map()) :: Phoenix.LiveView.Rendered.t()
  def banner(assigns) do
    # Mirror the real banner's box model (`branding_footer.css`) so its height
    # matches production (~58px), keeping the viewport-fit assertion faithful.
    ~H"""
    <div
      class="branding-footer"
      style="grid-row: 2; display: flex; justify-content: center; align-items: center; padding: 0.5rem 1rem;"
    >
      <div class="branding-footer-content" style="padding: 0.625rem 1rem; font-size: 0.875rem;">
        Like this booking page?
      </div>
    </div>
    """
  end
end
