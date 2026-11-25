defmodule TymeslotWeb.E2E.EmbedLoaderTest do
  @moduledoc """
  The embed loader, `priv/static/embed.js`, run on a host page of another
  origin, as an embedder's site runs it.

  The host page is served by a small Bandit server the test starts on
  `127.0.0.1` and a free port, while the app answers on `localhost`, so the
  booking page is framed cross-site: through the embed token, the cookie-free
  embed socket and the signed parent origin the embed auth hook checks
  against the organiser's allowlist. The loader's URL building is pinned in
  `assets/js/__tests__/embed.test.js`; this module proves the pieces meet in a
  real browser: what the framed page renders, the popup's open, close and
  focus behaviour, the floating button, and the frame's height following the
  `tymeslot-resize` messages `iframe_embed.js` posts.
  """
  use TymeslotWeb.BrowserCase, async: false

  import Tymeslot.TestHelpers.Eventually

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias TymeslotWeb.E2E.HostSite

  @moduletag :e2e
  @moduletag :themes

  @window {1280, 900}

  # What `iframe_embed.js` measures and posts: the booker's outer container,
  # margins included.
  @measure_content """
  const main = document.getElementsByClassName('main')[0] ||
    document.getElementsByTagName('main')[0] || document.documentElement;
  const s = getComputedStyle(main);
  return Math.ceil(parseFloat(s.height) + (parseFloat(s.marginTop) || 0) +
    (parseFloat(s.marginBottom) || 0));
  """

  feature "an inline embed renders the page its attributes ask for and follows its height",
          %{session: session} do
    profile = create_embeddable_profile(["127.0.0.1"])

    site =
      HostSite.start!(%{
        "/" =>
          HostSite.page("""
          <div id="tymeslot-booking" data-username="#{profile.username}" data-theme="1"
               data-locale="de" data-layout="column" data-initial-height="250"
               data-max-width="720"></div>
          """)
      })

    frame = "#tymeslot-booking iframe[title='Booking Widget']"
    wrapper = "#tymeslot-booking > div"

    session =
      session
      |> resize(@window)
      |> visit(site <> "/")
      |> assert_has(css(frame))

    # `data-max-width` caps the wrapper on a host page wider than it.
    assert evaluate_script(session, rect_width_js(wrapper)) == 720

    # The framed page is the one the attributes asked for, connected over the
    # embed socket: a parent origin off the allowlist would have redirected it
    # to the unavailable notice instead.
    session
    |> focus_frame(css(frame))
    |> assert_has(css("html.quill-theme[lang='de'][data-embedded][data-embed-layout='column']"))
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> assert_has(css("[data-testid='duration-option']", minimum: 1))
    |> focus_default_frame()
    |> assert_has(css(".tymeslot-loader", count: 0, visible: :any))

    # The wrapper leaves its 250px placeholder for the content's height...
    assert_wrapper_height(session, frame, wrapper, & &1)

    # ...grows with the content...
    set_content_min_height(session, frame, "1700px")
    assert_wrapper_height(session, frame, wrapper, & &1)
    assert wrapper_height(session, wrapper) >= 1700

    # ...and shrinks back with it, leaving no dead space under the booker.
    set_content_min_height(session, frame, "")
    assert_wrapper_height(session, frame, wrapper, & &1)
    assert wrapper_height(session, wrapper) < 1700
  end

  feature "the popup opens over the host page, keeps focus in, and closes three ways",
          %{session: session} do
    profile = create_embeddable_profile(["127.0.0.1"])

    site =
      HostSite.start!(%{
        "/" =>
          HostSite.page("""
          <a id="before" href="#top">Before</a>
          <button id="book" type="button"
                  onclick="TymeslotBooking.open('#{profile.username}', {theme: '1'})">Book</button>
          <div style="height: 3000px"></div>
          """)
      })

    modal_frame = "#tymeslot-modal iframe[title='Booking Widget']"
    modal_wrapper = "#tymeslot-modal [data-tymeslot-frame]"

    # Escape closes it, hands the page its scrolling back and puts focus on
    # the trigger. Pressed straight after opening: once the visitor is in the
    # booking frame, its keys go to the framed page, not to this one.
    session =
      session
      |> resize(@window)
      |> visit(site <> "/")
      |> open_popup()
      |> send_keys([:escape])
      |> assert_closed("book")
      |> open_popup()

    # The modal frames the booking page and caps its height at the window's,
    # less the headroom the close button sits in.
    session
    |> focus_frame(css(modal_frame))
    |> assert_has(css("html.quill-theme[data-embedded]"))
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> focus_default_frame()

    cap = evaluate_script(session, "return window.innerHeight - 100;")
    assert_wrapper_height(session, modal_frame, modal_wrapper, &min(&1, cap))

    set_content_min_height(session, modal_frame, "1700px")
    assert_wrapper_height(session, modal_frame, modal_wrapper, fn _content -> cap end)

    # The close button.
    session
    |> click(css("#tymeslot-modal [data-tymeslot-close]"))
    |> assert_closed("book")
    # A click on the backdrop, beside the dialog, the way a pointer makes it.
    |> open_popup()
    |> hover(css("#tymeslot-modal"))
    |> then(fn session ->
      # From the dialog's centre, where the hover left the pointer, to 8px
      # inside the window's top-left corner: the overlay's own padding.
      %{"x" => x, "y" => y} =
        evaluate_script(
          session,
          "return {x: Math.floor(window.innerWidth / 2), y: Math.floor(window.innerHeight / 2)};"
        )

      move_mouse_by(session, -x + 8, -y + 8)
    end)
    |> click(:left)
    |> assert_closed("book")
    # Shift+Tab from the dialog's first control wraps to its last, the
    # booking frame, rather than escaping to the host page behind it.
    |> open_popup()
    |> send_keys([:shift, :tab])
    |> assert_focus("modal-iframe")
    |> click(css("#tymeslot-modal [data-tymeslot-close]"))
    |> assert_closed("book")
  end

  feature "the floating button opens the popup in the embed's language",
          %{session: session} do
    profile = create_embeddable_profile(["127.0.0.1"])

    site =
      HostSite.start!(%{
        "/" =>
          HostSite.page("", """
          <script>
            TymeslotBooking.initFloating('#{profile.username}',
              {theme: '1', locale: 'de', buttonColor: '#e11d48'});
          </script>
          """)
      })

    button = "#tymeslot-floating-button"

    session =
      session
      |> resize(@window)
      |> visit(site <> "/")
      |> assert_has(css("#{button}[aria-label='Termin buchen']"))

    placement =
      evaluate_script(session, """
      const b = document.querySelector('#{button}');
      const r = b.getBoundingClientRect();
      return {
        colour: getComputedStyle(b).backgroundColor,
        right: Math.round(window.innerWidth - r.right),
        bottom: Math.round(window.innerHeight - r.bottom)
      };
      """)

    assert placement == %{"colour" => "rgb(225, 29, 72)", "right" => 24, "bottom" => 24}

    session
    |> click(css(button))
    |> assert_has(css("#tymeslot-modal[role='dialog'][aria-label='Buchungs-Widget']"))
    |> assert_has(css("[data-tymeslot-close][aria-label='Buchungs-Widget schließen']"))
    |> assert_focus("close")
    |> send_keys([:escape])
    |> assert_has(css("#tymeslot-modal", count: 0, visible: :any))
    |> assert_focus("tymeslot-floating-button")
    |> click(css(button))
    |> focus_frame(css("#tymeslot-modal iframe[title='Booking Widget']"))
    |> assert_has(css("html[lang='de'][data-embedded]"))
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> focus_default_frame()
    |> click(css("#tymeslot-modal [data-tymeslot-close]"))
    |> assert_has(css("#tymeslot-modal", count: 0, visible: :any))
    |> assert_focus("tymeslot-floating-button")
  end

  feature "a host page off the organiser's allowlist gets the unavailable notice",
          %{session: session} do
    profile = create_embeddable_profile(["embedder.test"])

    site =
      HostSite.start!(%{
        "/" =>
          HostSite.page(~s(<div id="tymeslot-booking" data-username="#{profile.username}"></div>))
      })

    session
    |> resize(@window)
    |> visit(site <> "/")
    |> focus_frame(css("#tymeslot-booking iframe[title='Booking Widget']"))
    |> assert_has(css("h1", text: "This booking page can’t be embedded here"))
    |> refute_has(css("[data-testid='duration-option']"))
  end

  defp resize(session, {width, height}), do: resize_window(session, width, height)

  # Opens the popup from the host page's button and checks the dialog took
  # the focus and the page's scrolling.
  defp open_popup(session) do
    session
    |> click(css("#book"))
    |> assert_has(css("#tymeslot-modal[role='dialog'][aria-modal='true']"))
    |> assert_focus("close")
    |> Kernel.tap(fn session ->
      assert evaluate_script(session, "return document.body.style.overflow;") == "hidden"
    end)
  end

  # The dialog is gone, the page scrolls again and the focus is back on the
  # element that opened it.
  defp assert_closed(session, trigger_id) do
    session = assert_has(session, css("#tymeslot-modal", count: 0, visible: :any))
    assert_focus(session, trigger_id)
    assert evaluate_script(session, "return document.body.style.overflow;") == ""
    session
  end

  # Names the host page's focused element: "close" for the dialog's close
  # button, "modal-iframe" for the dialog's booking frame, else its id.
  defp assert_focus(session, expected) do
    eventually(
      fn ->
        assert evaluate_script(session, """
               const a = document.activeElement;
               if (!a) return null;
               if (a.hasAttribute('data-tymeslot-close')) return 'close';
               const modal = document.getElementById('tymeslot-modal');
               if (a.tagName === 'IFRAME' && modal && modal.contains(a)) return 'modal-iframe';
               return a.id || a.tagName.toLowerCase();
               """) == expected
      end,
      timeout: 3_000
    )

    session
  end

  # Waits until the wrapper's applied height is `expected.(content)`, where
  # `content` is the framed page's height measured as `iframe_embed.js`
  # measures it. Both are re-read on every attempt, since the page posts on a
  # 50ms loop and a shrink only once it has held for a tick.
  defp assert_wrapper_height(session, frame, wrapper, expected) do
    eventually(
      fn ->
        content =
          session
          |> focus_frame(css(frame))
          |> evaluate_script(@measure_content)

        focus_default_frame(session)

        assert wrapper_height(session, wrapper) == expected.(content)
      end,
      timeout: 5_000,
      interval: 100
    )
  end

  defp wrapper_height(session, wrapper) do
    evaluate_script(
      session,
      "return parseFloat(document.querySelector(#{Jason.encode!(wrapper)}).style.height);"
    )
  end

  defp set_content_min_height(session, frame, value) do
    session
    |> focus_frame(css(frame))
    |> execute_script("""
    const main = document.getElementsByClassName('main')[0] ||
      document.getElementsByTagName('main')[0];
    main.style.minHeight = #{Jason.encode!(value)};
    """)
    |> focus_default_frame()
  end

  defp rect_width_js(selector),
    do:
      "return Math.round(document.querySelector(#{Jason.encode!(selector)}).getBoundingClientRect().width);"

  defp create_embeddable_profile(domains) do
    user = create_onboarded_user()
    insert(:calendar_integration, user_id: user.id, user: user)

    {:ok, _meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Embed Loader Check",
        duration_minutes: 30,
        is_active: true
      })

    user.id
    |> Profiles.get_profile()
    |> Changeset.change(allowed_embed_domains: domains)
    |> Repo.update!()
  end
end
