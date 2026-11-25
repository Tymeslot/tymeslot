defmodule TymeslotWeb.E2E.ClipboardCopyTest do
  @moduledoc """
  The dashboard's copy buttons put the exact text on the clipboard and say
  so:

    * the sidebar's booking link, copied in the browser by `CopyOnClick`
      (`assets/js/utility_hooks.js`), confirmed by its toast and recorded as
      the profile's first share;
    * an embed snippet, built by the server and pushed to the page as
      `copy-to-clipboard`, which the `ClipboardCopy` hook
      (`assets/js/clipboard_hook.js`) copies, confirmed by a flash.

  A driven Chrome refuses clipboard reads, so `navigator.clipboard` is
  replaced on the page with one that records what it is given
  (`record_clipboard/1`). Everything up to that call is the app's own code.
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :dashboard

  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Profiles
  alias TymeslotWeb.Endpoint

  feature "the sidebar copies the booking link and records the first share",
          %{session: session} do
    {session, user} = log_in_via_browser(session)
    insert(:calendar_integration, user: user, is_active: true)
    %{username: username} = Profiles.get_profile(user.id)
    refute_shared(user)

    session =
      session
      |> visit("/dashboard/settings")
      |> wait_for_live()
      |> record_clipboard()
      |> click(css("#copy-scheduling-link"))
      |> assert_has(css("p", text: "Scheduling link copied to clipboard!"))

    assert copied(session) == ["#{Endpoint.url()}/#{username}"]

    # The copy also tells the server, which stamps the first share.
    eventually_shared(user)
  end

  feature "an embed snippet copies exactly the code shown beside it", %{session: session} do
    {session, user} = log_in_via_browser(session)
    insert(:calendar_integration, user: user, is_active: true)
    %{username: username} = Profiles.get_profile(user.id)
    refute_shared(user)

    copy = "button[phx-click='copy_code'][phx-value-type='inline']"

    session =
      session
      |> visit("/dashboard/embed")
      |> wait_for_live()
      |> record_clipboard()
      |> click(css(copy))
      |> assert_has(css("#app-flash-group-info", text: "Code copied to clipboard!"))

    # Written once, by the `ClipboardCopy` hook answering the server's
    # `copy-to-clipboard`.
    assert [snippet] = copied(session)

    assert snippet =~ ~s(<div id="tymeslot-booking" data-username="#{username}")
    assert snippet =~ ~s(<script src="#{Endpoint.url()}/embed.js" async></script>)

    # What the organiser read on the card is what they pasted, line by line;
    # the card only drops the indentation.
    shown =
      evaluate_script(
        session,
        "return document.querySelector(arguments[0]).parentElement.querySelector('code').innerText",
        [copy]
      )

    assert lines(snippet) == lines(shown)
    eventually_shared(user)
  end

  # Swaps the page's clipboard for one that records each text it is given
  # and succeeds, as the real one does once the browser allows it.
  defp record_clipboard(session) do
    execute_script(session, """
    window.__copied = [];
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {writeText: (text) => { window.__copied.push(text); return Promise.resolve(); }}
    });
    """)
  end

  defp copied(session), do: evaluate_script(session, "return window.__copied")

  defp evaluate_script(session, script, args) do
    me = self()
    ref = make_ref()
    execute_script(session, script, args, &send(me, {ref, &1}))
    assert_receive {^ref, value}, 5_000
    value
  end

  defp lines(text), do: text |> String.split("\n") |> Enum.map(&String.trim/1)

  # Nothing before the copy (signing in, the page's mount) stamps the first
  # share, so the stamp afterwards is the copy's.
  defp refute_shared(user),
    do: assert(Profiles.get_profile(user.id).booking_link_first_shared_at == nil)

  defp eventually_shared(user) do
    eventually(
      fn -> match?(%DateTime{}, Profiles.get_profile(user.id).booking_link_first_shared_at) end,
      timeout: 3_000,
      message: "the copy was never recorded as the booking link's first share"
    )
  end
end
