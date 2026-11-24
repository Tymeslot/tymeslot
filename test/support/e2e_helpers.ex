defmodule TymeslotWeb.E2EHelpers do
  @moduledoc """
  Shared browser interaction helpers for E2E tests.
  """

  use Fluffy.Assert

  import Fluffy
  import Fluffy.Locator
  import Fluffy.Playwright, only: [evaluate: 3, evaluate: 4, set_viewport_size: 2]

  alias Phoenix.ConnTest
  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.AuthTestHelpers
  alias Tymeslot.Factory
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias TymeslotWeb.Endpoint

  @default_password "Password123!"

  # The narrowest viewport the design system targets, and the one the booking
  # themes are already guarded at in `EmbedSizesMatrixTest`. Keeping a single
  # floor across the suite means "fits on a phone" means the same thing
  # everywhere. The height matches the mobile viewport in `DashboardTourTest`.
  @mobile_viewport %{width: 320, height: 844}

  # Sub-pixel rounding can report scrollWidth one px over innerWidth even when
  # the page genuinely fits.
  @overflow_tolerance 1

  @doc """
  Returns the default password used by the user factory.
  """
  @spec default_password() :: String.t()
  def default_password, do: @default_password

  @doc """
  Logs in a user via the browser login form, for a test about the form or
  what signing in shows; `log_in/2` skips the form.

  Creates a verified user (with onboarding completed and a profile) from the
  given attributes, then navigates to `/auth/login`, fills the form, and waits
  for the dashboard to load.

  Returns `{session, user}`.
  """
  @spec log_in_via_browser(Fluffy.Session.t(), map()) :: {Fluffy.Session.t(), UserSchema.t()}
  def log_in_via_browser(session, user_attrs \\ %{}) do
    user = create_onboarded_user(user_attrs)

    session =
      session
      |> visit("/auth/login")
      |> fill(by_label("Email Address"), user.email)
      |> fill(by_css("#password-input"), @default_password)
      |> click(by_css("button[type='submit']"))
      |> wait_for_dashboard()

    {session, user}
  end

  @doc """
  Logs in a user without the login form, for a test that isn't about it.

  Creates a verified user (with onboarding completed and a profile) from the
  given attributes and gives the browser the session cookie a login would set:
  the app's own `Tymeslot.AuthTestHelpers.log_in_user/2` signs the user in on
  an in-process conn, and one request through the endpoint writes the cookie.
  The browser stays where it is; the test visits its first page itself.

  Returns `{session, user}`.
  """
  @spec log_in(Fluffy.Session.t(), map()) :: {Fluffy.Session.t(), UserSchema.t()}
  def log_in(session, user_attrs \\ %{}) do
    user = create_onboarded_user(user_attrs)
    {log_in_as(session, user), user}
  end

  @doc """
  Gives the browser the session cookie of `user`, as `log_in/2` does, for a
  user the test has already created.
  """
  @spec log_in_as(Fluffy.Session.t(), UserSchema.t()) :: Fluffy.Session.t()
  def log_in_as(session, user) do
    conn =
      ConnTest.build_conn()
      |> PlugTest.init_test_session(%{})
      |> AuthTestHelpers.log_in_user(user)
      |> ConnTest.dispatch(Endpoint, :get, "/", nil)

    cookies =
      for {name, %{value: value}} <- conn.resp_cookies,
          do: %{name: name, value: value, url: Fluffy.base_url(session)}

    add_cookies(session, cookies)
  end

  @doc """
  Waits for the page's LiveView to connect.

  `[data-phx-main]` alone is not enough: the server renders it into the static
  HTML, so it is there before the JavaScript bundle has even run. A click in
  that window reaches a button with no one listening, and one that lands after
  the bundle has run but before the channel has joined is dropped by the
  LiveView client (`pushWithReply` answers "no connection" without sending
  anything). Either way the event never reaches the server and nothing reports
  it. The client adds `phx-connected` to the root once the join succeeds, so
  that is what makes the page interactive.
  """
  @spec wait_for_live(Fluffy.Session.t()) :: Fluffy.Session.t()
  def wait_for_live(session) do
    assert_has(session, first(by_css("[data-phx-main].phx-connected")))
  end

  @doc """
  Waits for the dashboard to appear after login, with its LiveView connected
  (see `wait_for_live/1`).
  """
  @spec wait_for_dashboard(Fluffy.Session.t()) :: Fluffy.Session.t()
  def wait_for_dashboard(session) do
    session
    |> assert_has(by_css("#dashboard-root"))
    |> wait_for_live()
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
  The narrowest viewport the design system targets, for a test that runs at it
  throughout: `@tag Playwright.Test.use(viewport: E2EHelpers.mobile_viewport())`.
  """
  @spec mobile_viewport() :: %{width: pos_integer(), height: pos_integer()}
  def mobile_viewport, do: @mobile_viewport

  @doc """
  Resizes the browser to `mobile_viewport/0`, for a test that switches to it
  part way through.

  Resize *before* navigating rather than after. Measuring a page that was laid
  out wide and then squeezed races any width transition still in flight; a
  fresh load at the target width does not.
  """
  @spec resize_to_mobile(Fluffy.Session.t()) :: Fluffy.Session.t()
  def resize_to_mobile(session), do: set_viewport_size(session, @mobile_viewport)

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
  the width. With `frame`, it measures the document inside that frame (see
  `evaluate_script/4`).
  """
  @spec assert_no_horizontal_overflow(
          Fluffy.Session.t(),
          String.t(),
          Fluffy.FrameLocator.t() | nil
        ) :: Fluffy.Session.t()
  def assert_no_horizontal_overflow(session, context, frame \\ nil) do
    culprits = evaluate_script(session, overflow_script(), frame)

    assert culprits == [],
           """
           Horizontal overflow at #{context}:

           #{Enum.map_join(culprits, "\n", &"  - #{&1}")}
           """

    session
  end

  @doc """
  A CSS locator in the page, or inside `frame`, a `Fluffy.Locator.frame_locator/1`,
  for the steps that run in both.
  """
  @spec css_in(Fluffy.FrameLocator.t() | nil, String.t()) :: Fluffy.Locator.t()
  def css_in(nil, selector), do: by_css(selector)
  def css_in(frame, selector), do: by_css(frame, selector)

  @doc """
  The element with `data-testid` `test_id`, in the page or inside `frame`, as
  `css_in/2`.
  """
  @spec test_id_in(Fluffy.FrameLocator.t() | nil, String.t()) :: Fluffy.Locator.t()
  def test_id_in(nil, test_id), do: by_test_id(test_id)
  def test_id_in(frame, test_id), do: by_test_id(frame, test_id)

  @doc """
  Runs `script`, a function body, in the page and returns the value its
  `return` statement yields, for an assertion to inspect. The body can read
  `arg`. JavaScript's `null` comes back as `:null`.

  With `frame`, a `Fluffy.Locator.frame_locator/1`, the script runs in that
  frame's document instead.
  """
  @spec evaluate_script(Fluffy.Session.t(), String.t(), Fluffy.FrameLocator.t() | nil, term()) ::
          term()
  def evaluate_script(session, script, frame \\ nil, arg \\ nil)

  def evaluate_script(session, script, nil, arg),
    do: evaluate(session, "(arg) => {\n#{script}\n}", arg)

  def evaluate_script(session, script, frame, arg) do
    evaluate(
      session,
      by_css(frame, ":root"),
      "(_root, arg) => {\n#{script}\n}",
      arg
    )
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
