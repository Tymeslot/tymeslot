defmodule TymeslotWeb.E2EHelpers do
  @moduledoc """
  Shared browser interaction helpers for E2E tests.
  """

  import ExUnit.Assertions
  import Wallaby.Browser
  import Wallaby.Query

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Factory
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries

  @default_password "Password123!"

  # The narrowest viewport the design system targets, and the one the booking
  # themes are already guarded at in `EmbedSizesMatrixTest`. Keeping a single
  # floor across the suite means "fits on a phone" means the same thing
  # everywhere. The height matches the mobile viewport in `DashboardTourTest`.
  @mobile_viewport {320, 844}

  # Sub-pixel rounding in the WebDriver bridge can report scrollWidth one px
  # over innerWidth even when the page genuinely fits.
  @overflow_tolerance 1

  @doc """
  Returns the default password used by the user factory.
  """
  @spec default_password() :: String.t()
  def default_password, do: @default_password

  @doc """
  Logs in a user via the browser login form.

  Creates a verified user (with onboarding completed and a profile) from the
  given attributes, then navigates to `/auth/login`, fills the form, and waits
  for the dashboard to load.

  Returns `{session, user}`.
  """
  @spec log_in_via_browser(Wallaby.Session.t(), map()) :: {Wallaby.Session.t(), UserSchema.t()}
  def log_in_via_browser(session, user_attrs \\ %{}) do
    user = create_onboarded_user(user_attrs)

    session =
      session
      |> visit("/auth/login")
      |> wait_for_live()
      |> fill_in(text_field("email"), with: user.email)
      |> fill_in(css("#password-input"), with: @default_password)
      |> click(css("button[type='submit']"))
      |> wait_for_dashboard()

    {session, user}
  end

  @doc """
  Waits for LiveView to mount by checking for `[data-phx-main]`.
  """
  @spec wait_for_live(Wallaby.Session.t()) :: Wallaby.Session.t()
  def wait_for_live(session) do
    assert_has(session, css("[data-phx-main]", count: :any, minimum: 1))
  end

  @doc """
  Waits for the dashboard to appear after login.
  """
  @spec wait_for_dashboard(Wallaby.Session.t()) :: Wallaby.Session.t()
  def wait_for_dashboard(session) do
    assert_has(session, css("#dashboard-root"))
  end

  @doc """
  Creates a verified user with onboarding completed and a profile.

  This is the typical starting state for tests that need an authenticated
  user who can access the dashboard without being redirected to onboarding.
  """
  @spec create_onboarded_user(map()) :: UserSchema.t()
  def create_onboarded_user(attrs \\ %{}) do
    user =
      Factory.insert(
        :user,
        Map.merge(
          %{
            onboarding_completed_at: DateTime.utc_now(:second)
          },
          attrs
        )
      )

    {:ok, profile} = Profiles.get_or_create_profile(user.id)

    # Ensure the profile has a username so tests that build URLs like
    # /:username/... don't generate nil-based paths.
    unless profile.username do
      username = Profiles.generate_default_username(user.id)
      {:ok, _profile} = ProfileQueries.update_username(profile, username)
    end

    user
  end

  @doc """
  Resizes the browser to the narrowest viewport the design system targets.

  Resize *before* navigating rather than after. Measuring a page that was laid
  out wide and then squeezed races any width transition still in flight; a
  fresh load at the target width does not.
  """
  @spec resize_to_mobile(Wallaby.Session.t()) :: Wallaby.Session.t()
  def resize_to_mobile(session) do
    {width, height} = @mobile_viewport
    resize_window(session, width, height)
  end

  @doc """
  Asserts no element extends past the right edge of the viewport.

  Measures each element's own `getBoundingClientRect().right` rather than
  `document.documentElement.scrollWidth`. That is not a refinement, it is the
  only thing that works here: `assets/css/base/base.css` sets
  `html, body { overflow-x: hidden }`, which clamps `scrollWidth` to the
  viewport on every main-app page. A document-level check there reports a tidy
  320px while a 900px element sits off the edge, so it can never fail. Element
  rects are not clamped by an ancestor's overflow, so they still tell the truth.
  The scheduling themes use a different root layout and do not clamp `html`,
  which is why the document-level check worked for them.

  A clip or a scroller on an inner container is respected: an element inside one
  is meant to be clipped or scrolled, and is skipped. The same declaration on
  `body` or `html` is the page-level clamp this assertion exists to see through,
  so the ancestor walk deliberately stops short of both.

  Only the outermost offender in each chain is reported. An overflowing card
  drags every descendant past the edge with it, and naming fifty children buries
  the one element worth fixing.

  `context` is quoted verbatim in the failure message, so name the screen and
  the width.
  """
  @spec assert_no_horizontal_overflow(Wallaby.Session.t(), String.t()) :: Wallaby.Session.t()
  def assert_no_horizontal_overflow(session, context) do
    me = self()
    ref = make_ref()

    session =
      execute_script(session, overflow_script(), fn culprits ->
        send(me, {:overflow, ref, culprits})
      end)

    assert_receive {:overflow, ^ref, culprits}, 5_000

    assert culprits == [],
           """
           Horizontal overflow at #{context}:

           #{Enum.map_join(culprits, "\n", &"  - #{&1}")}
           """

    session
  end

  defp overflow_script do
    """
    const limit = window.innerWidth + #{@overflow_tolerance};

    function clipped(el) {
      let parent = el.parentElement;
      while (parent && parent !== document.body && parent !== document.documentElement) {
        const overflowX = getComputedStyle(parent).overflowX;
        if (overflowX === 'auto' || overflowX === 'scroll' || overflowX === 'hidden') return true;
        parent = parent.parentElement;
      }
      return false;
    }

    function hidden(el) {
      const style = getComputedStyle(el);
      return style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0';
    }

    function describe(el) {
      let out = el.tagName.toLowerCase();
      if (el.id) out += '#' + el.id;
      const classes = (el.getAttribute('class') || '').trim().split(/\s+/).filter(Boolean);
      if (classes.length) out += '.' + classes.slice(0, 2).join('.');
      return out;
    }

    const reported = [];
    const culprits = [];

    document.body.querySelectorAll('*').forEach(function (el) {
      const rect = el.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) return;
      if (rect.right <= limit) return;
      if (hidden(el)) return;
      if (clipped(el)) return;
      if (reported.some(function (ancestor) { return ancestor.contains(el); })) return;
      reported.push(el);
      culprits.push(describe(el) + ' extends ' + Math.round(rect.right - limit) + 'px past the viewport');
    });

    return culprits;
    """
  end
end
