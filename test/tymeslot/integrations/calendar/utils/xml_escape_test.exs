defmodule Tymeslot.Integrations.Calendar.Utils.XmlEscapeTest do
  @moduledoc """
  Covers the escaper the CalDAV and EWS request builders share.

  The load-bearing test is the round trip. Asserting one character at a time
  cannot see an ordering mistake: escaping `&` last would turn every entity
  the other four replacements introduced into `&amp;lt;` and friends, and each
  individual character would still appear escaped in the output. Only parsing
  the document back and comparing the value byte-for-byte catches it.
  """

  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :unit

  import SweetXml, only: [sigil_x: 2, xpath: 2]

  alias Tymeslot.Integrations.Calendar.Utils.XmlEscape

  # Every metacharacter, plus the entity-looking text that a wrong replacement
  # order would corrupt.
  @hostile ~s(Chars & "Quotes" <b> 'x' &amp; 5 > 3)

  describe "escape/1" do
    test "a text node survives the round trip byte-for-byte" do
      document = "<v>#{XmlEscape.escape(@hostile)}</v>"

      assert xpath(document, ~x"//v/text()"s) == @hostile
    end

    test "an attribute survives the round trip byte-for-byte" do
      # Both interpolation sites are exercised: the EWS builders escape into
      # attributes, the CalDAV one into a text node, and an escaper correct
      # for only one of them would be a latent bug in the other.
      document = ~s(<v a="#{XmlEscape.escape(@hostile)}"/>)

      assert xpath(document, ~x"//v/@a"s) == @hostile
    end

    test "escapes each of the five metacharacters" do
      assert XmlEscape.escape(~s(&<>"')) == "&amp;&lt;&gt;&quot;&apos;"
    end

    test "replaces the ampersand first" do
      # Stated as its own assertion because the round-trip tests above would
      # also fail for a dozen other reasons, and this names the one that
      # matters. Escaping `&` last yields "&amp;lt;" here.
      assert XmlEscape.escape("<") == "&lt;"
      assert XmlEscape.escape("&<") == "&amp;&lt;"
    end

    test "leaves ordinary text untouched" do
      assert XmlEscape.escape("hello world") == "hello world"
    end

    test "refuses a non-binary rather than rendering it as empty" do
      # A `nil` reaching a request body must raise here. Rendered as "", it
      # would produce a well-formed request that means something else — an
      # empty sync token, or an item id addressing nothing.
      #
      # Fetched rather than written literally: the compiler can prove a literal
      # `nil` matches no clause and warns, which the build treats as an error.
      absent = System.get_env("TYMESLOT_XML_ESCAPE_NEVER_SET")

      assert_raise FunctionClauseError, fn -> XmlEscape.escape(absent) end
    end
  end
end
