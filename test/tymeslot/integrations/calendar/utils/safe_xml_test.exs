defmodule Tymeslot.Integrations.Calendar.Utils.SafeXmlTest do
  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :unit

  import SweetXml, only: [sigil_x: 2, add_namespace: 3, transform_by: 2]

  alias Tymeslot.Integrations.Calendar.Utils.SafeXml

  @multistatus """
  <?xml version="1.0" encoding="utf-8"?>
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response>
      <D:href>/cal/one.ics</D:href>
      <D:propstat>
        <D:prop>
          <D:getetag>"etag-1"</D:getetag>
          <C:calendar-data><![CDATA[BEGIN:VCALENDAR]]>&#10;END:VCALENDAR</C:calendar-data>
          <C:supported-calendar-component-set>
            <C:comp name="VEVENT"/><C:comp name="VTODO"/>
          </C:supported-calendar-component-set>
        </D:prop>
      </D:propstat>
    </D:response>
    <D:response>
      <D:href>/cal/two.ics</D:href>
      <D:propstat><D:prop><D:privilege><D:write-content/></D:privilege></D:prop></D:propstat>
    </D:response>
  </D:multistatus>
  """

  defp nested(name, depth),
    do: String.duplicate("<#{name}>", depth) <> "x" <> String.duplicate("</#{name}>", depth)

  defp parse!(xml) do
    {:ok, doc} = SafeXml.parse(xml)
    doc
  end

  describe "parse/1" do
    test "keeps names as binaries, resolved to their namespace URI" do
      assert %SafeXml{namespace: "DAV:", name: "multistatus"} = parse!(@multistatus)
    end

    test "merges a CDATA section with the text around it into one value" do
      doc = parse!(@multistatus)

      assert SafeXml.xpath(doc, ~x"//*[local-name()='calendar-data']/text()"l) ==
               ["BEGIN:VCALENDAR\nEND:VCALENDAR"]
    end

    test "refuses a document declaring an internal entity" do
      xml = ~s(<?xml version="1.0"?><!DOCTYPE r [<!ENTITY a "x">]><r>&a;</r>)

      assert SafeXml.parse(xml) == {:error, :doctype_not_allowed}
    end

    test "refuses a DOCTYPE naming an external DTD before reading it" do
      xml = ~s(<?xml version="1.0"?><!DOCTYPE r SYSTEM "file:///etc/passwd"><r>hi</r>)

      assert SafeXml.parse(xml) == {:error, :doctype_not_allowed}
    end

    test "accepts a bare DOCTYPE, which declares nothing" do
      xml = ~s(<?xml version="1.0"?><!DOCTYPE r><r>hi</r>)

      assert {:ok, %SafeXml{name: "r", children: ["hi"]}} = SafeXml.parse(xml)
    end

    test "reports malformed input by line without quoting it" do
      assert SafeXml.parse("<a>\n<Secret></a>") == {:error, {:malformed_xml, 2}}
    end

    test "reports input that is not XML at all as malformed" do
      assert {:error, {:malformed_xml, _line}} = SafeXml.parse("")
      assert {:error, {:malformed_xml, _line}} = SafeXml.parse("this is not xml <<<")
    end

    test "parses a document nested exactly 64 elements deep" do
      assert {:ok, %SafeXml{name: "a"} = doc} = SafeXml.parse(nested("a", 64))
      assert SafeXml.xpath(doc, ~x"//a/text()"l) == ["x"]
    end

    test "refuses a document nested one element past the limit" do
      assert SafeXml.parse(nested("a", 65)) == {:error, :too_deep}
    end

    # The refusal comes at the first element past the limit, so a document
    # nested as deep as a response's byte cap allows costs no more to refuse
    # than a shallow one.
    test "refuses a hostile deeply nested document quickly" do
      xml = nested("a", 500_000)

      {microseconds, result} = :timer.tc(fn -> SafeXml.parse(xml) end)

      assert result == {:error, :too_deep}
      # A quadratic walk of this depth takes tens of seconds, so 10 s still
      # tells the two apart on a machine too loaded to finish in one.
      assert microseconds < 10_000_000
    end
  end

  describe "xpath/3" do
    test "returns descendant matches in document order" do
      doc = parse!(~s(<r><a>1<a>2<a>3</a></a></a><b><a>4</a></b><a>5</a></r>))

      assert SafeXml.xpath(doc, ~x"//a/text()"l) == ["1", "2", "3", "4", "5"]
    end

    # `parse/1` refuses deep nesting, but a walk that copies each subtree once
    # per level would take tens of seconds over this tree, built directly; a
    # linear one takes milliseconds.
    test "searches a deeply nested document in time linear in its size" do
      leaf = %SafeXml{namespace: "", name: "a", children: ["x"]}

      doc =
        Enum.reduce(2..200_000//1, leaf, fn _level, child ->
          %SafeXml{namespace: "", name: "a", children: [child]}
        end)

      {microseconds, matches} = :timer.tc(fn -> SafeXml.xpath(doc, ~x"//a/text()"l) end)

      assert matches == ["x"]
      assert microseconds < 5_000_000
    end

    test "matches a prefixed step on the namespace URI, not on the prefix" do
      doc =
        parse!(
          ~s(<x:root xmlns:x="urn:a"><x:item>1</x:item><y:item xmlns:y="urn:b">2</y:item></x:root>)
        )

      spec = add_namespace(~x"//a:item/text()"l, "a", "urn:a")

      assert SafeXml.xpath(doc, spec) == ["1"]
    end

    test "matches an unprefixed step only on elements in no namespace" do
      doc = parse!(~s(<root><item>1</item><item xmlns="urn:a">2</item></root>))

      assert SafeXml.xpath(doc, ~x"./item/text()"l) == ["1"]
    end

    test "matches any of the local names an or-predicate lists" do
      doc = parse!(@multistatus)

      spec =
        ~x".//*[local-name()='privilege']/*[local-name()='write' or local-name()='write-content']"l

      assert [%SafeXml{name: "write-content"}] = SafeXml.xpath(doc, spec)
    end

    test "reads attribute values, as a list with the l modifier" do
      doc = parse!(@multistatus)

      assert SafeXml.xpath(doc, ~x"//*[local-name()='comp']/@name"sl) == ["VEVENT", "VTODO"]
    end

    test "concatenates every match under a string cast, and answers \"\" for none" do
      doc = parse!(@multistatus)

      assert SafeXml.xpath(doc, ~x"//*[local-name()='href']/text()"s) ==
               "/cal/one.ics/cal/two.ics"

      assert SafeXml.xpath(doc, ~x"//*[local-name()='missing']/text()"s) == ""
    end

    test "answers the first match without a cast, and nil for none" do
      doc = parse!(@multistatus)

      assert %SafeXml{name: "response"} = SafeXml.xpath(doc, ~x"//*[local-name()='response']")
      assert SafeXml.xpath(doc, ~x"//*[local-name()='missing']"o) == nil
    end

    test "maps each match through subspecs, nested ones included" do
      doc = parse!(@multistatus)

      assert SafeXml.xpath(doc, ~x"//*[local-name()='response']"l,
               href: ~x"./*[local-name()='href']/text()"s,
               etag: ~x".//*[local-name()='getetag']/text()"s,
               writable: transform_by(~x".//*[local-name()='write-content']", &(&1 != nil)),
               prop: [
                 ~x".//*[local-name()='prop']",
                 etag: ~x"./*[local-name()='getetag']/text()"s
               ]
             ) == [
               %{
                 href: "/cal/one.ics",
                 etag: ~s("etag-1"),
                 writable: false,
                 prop: %{etag: ~s("etag-1")}
               },
               %{href: "/cal/two.ics", etag: "", writable: true, prop: %{etag: ""}}
             ]
    end

    test "reads an absolute path from an element as rooted at that element" do
      doc = parse!(@multistatus)
      [_first, second] = SafeXml.xpath(doc, ~x"//*[local-name()='response']"l)

      assert SafeXml.xpath(second, ~x"//*[local-name()='href']/text()"s) == "/cal/two.ics"
    end

    test "raises on an expression outside the supported subset" do
      doc = parse!(@multistatus)

      assert_raise ArgumentError, ~r/does not support the xpath/, fn ->
        SafeXml.xpath(doc, ~x"//*[contains(name(), 'href')]"l)
      end
    end

    test "raises on a prefix the expression does not bind" do
      doc = parse!(@multistatus)

      assert_raise ArgumentError, ~r/unbound namespace prefix/, fn ->
        SafeXml.xpath(doc, ~x"//d:href"l)
      end
    end
  end
end
