defmodule Tymeslot.GettextCheck.DomainMoveTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support
  @moduletag :i18n

  alias Expo.PO
  alias Tymeslot.GettextCheck.DomainMove

  describe "rewrite_source/3" do
    test "rewrites every gettext call form naming the domain, and nothing else" do
      source = """
      dgettext("booking", "Book")
      dngettext("booking", "1 slot", "%{count} slots", n)
      dpgettext("booking", "button", "Book")
      dgettext_noop("booking", "Later")
      Gettext.dgettext(TymeslotWeb.Gettext, "booking", msgid)
      dgettext("booking_manage", "Cancel")
      dgettext("emails", "booking")
      dgettext(
        "booking",
        "Wrapped"
      )
      """

      {rewritten, count} = DomainMove.rewrite_source(source, "booking", "booking_errors")

      assert count == 6

      assert rewritten == """
             dgettext("booking_errors", "Book")
             dngettext("booking_errors", "1 slot", "%{count} slots", n)
             dpgettext("booking_errors", "button", "Book")
             dgettext_noop("booking_errors", "Later")
             Gettext.dgettext(TymeslotWeb.Gettext, "booking_errors", msgid)
             dgettext("booking_manage", "Cancel")
             dgettext("emails", "booking")
             dgettext(
               "booking_errors",
               "Wrapped"
             )
             """
    end
  end

  describe "runtime_references/2" do
    test "lists literals outside gettext calls, which a lookup may read later" do
      source = """
      @domain "booking"
      dgettext("booking", "Book")
      dgettext(
        "booking",
        "Wrapped by the formatter"
      )
      """

      assert DomainMove.runtime_references(source, "booking") == [{1, ~s(@domain "booking")}]
    end
  end

  describe "snapshot/2 and carry/3" do
    setup do
      priv = Path.join(System.tmp_dir!(), "domain_move_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(priv) end)
      %{priv: priv}
    end

    test "carries translations into the new domain and repairs fuzzy matches", %{priv: priv} do
      write(priv, "de", "booking", """
      msgid "Book"
      msgstr "Buchen"

      msgid "1 slot"
      msgid_plural "%{count} slots"
      msgstr[0] "1 Termin"
      msgstr[1] "%{count} Termine"
      """)

      write(priv, "en", "booking", ~s(msgid "Book"\nmsgstr ""\n))

      snapshot = DomainMove.snapshot(priv, ["booking", "booking_errors"])

      # What `extract --merge` leaves behind: empty entries, and a wrong fuzzy match.
      write(priv, "de", "booking_errors", """
      #, fuzzy
      msgid "Book"
      msgstr "Falsch"

      msgid "1 slot"
      msgid_plural "%{count} slots"
      msgstr[0] ""
      msgstr[1] ""

      msgid "New"
      msgstr ""
      """)

      write(priv, "en", "booking_errors", ~s(#, fuzzy\nmsgid "Book"\nmsgstr "Bok"\n))

      assert DomainMove.carry(priv, "booking_errors", snapshot) == %{"de" => [{"", "New"}]}

      messages = PO.parse_file!(po(priv, "de", "booking_errors")).messages
      [book, slot, _new] = messages

      assert IO.iodata_to_binary(book.msgstr) == "Buchen"
      assert book.flags == []

      assert Map.new(slot.msgstr, fn {n, s} -> {n, IO.iodata_to_binary(s)} end) ==
               %{0 => "1 Termin", 1 => "%{count} Termine"}

      # English stays empty, fuzzy matches included: the msgid is the English.
      assert [%{msgstr: [""], flags: []}] =
               PO.parse_file!(po(priv, "en", "booking_errors")).messages
    end
  end

  defp write(priv, locale, domain, body) do
    path = po(priv, locale, domain)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp po(priv, locale, domain), do: Path.join([priv, locale, "LC_MESSAGES", domain <> ".po"])
end
