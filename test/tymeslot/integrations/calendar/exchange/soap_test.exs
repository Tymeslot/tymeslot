defmodule Tymeslot.Integrations.Calendar.Exchange.SoapTest do
  use ExUnit.Case, async: true

  import SweetXml, except: [xpath: 2, xpath: 3]

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Test.LogCapture

  # Binds the EWS namespaces to prefixes no xpath in this codebase spells, so
  # anything that resolves against it can only have resolved by namespace URI.
  @renamed_prefixes """
  <?xml version="1.0"?>
  <env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
    <env:Body>
      <msgs:GetItemResponse
          xmlns:msgs="http://schemas.microsoft.com/exchange/services/2006/messages"
          xmlns:types="http://schemas.microsoft.com/exchange/services/2006/types">
        <msgs:ResponseMessages>
          <msgs:GetItemResponseMessage ResponseClass="Success">
            <msgs:ResponseCode>NoError</msgs:ResponseCode>
            <msgs:Items>
              <types:CalendarItem>
                <types:Subject>Standup</types:Subject>
              </types:CalendarItem>
            </msgs:Items>
          </msgs:GetItemResponseMessage>
        </msgs:ResponseMessages>
      </msgs:GetItemResponse>
    </env:Body>
  </env:Envelope>
  """

  describe "envelope/1" do
    test "wraps a body in a SOAP envelope carrying the Exchange2013 version header" do
      xml = Soap.envelope("<m:GetFolder/>")

      assert xml =~ ~s(<soap:Envelope)
      assert xml =~ ~s(xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types")
      assert xml =~ ~s(xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages")
      assert xml =~ ~s(<t:RequestServerVersion Version="Exchange2013"/>)
      assert xml =~ "<m:GetFolder/>"
    end

    test "produces a document parse/1 accepts and the EWS prefixes resolve against" do
      assert {:ok, doc} = "<m:GetFolder/>" |> Soap.envelope() |> Soap.parse()

      assert Soap.xpath(doc, ~x"//t:RequestServerVersion/@Version"s) == "Exchange2013"
      assert Soap.xpath(doc, ~x"//m:GetFolder"l) != []
    end
  end

  describe "parse/1" do
    test "returns the parsed document for a successful response" do
      body = """
      <?xml version="1.0"?>
      <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP:Body><m:Ok xmlns:m="urn:m"/></SOAP:Body>
      </SOAP:Envelope>
      """

      assert {:ok, doc} = Soap.parse(body)
      assert elem(doc, 0) == :xmlElement
    end

    test "returns the fault string when the server answers a SOAP fault" do
      body = """
      <?xml version="1.0"?>
      <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP:Body><SOAP:Fault>
          <faultcode>SOAP:Server</faultcode>
          <faultstring>Invalid SOAP envelope</faultstring>
        </SOAP:Fault></SOAP:Body>
      </SOAP:Envelope>
      """

      assert {:error, {:soap_fault, "Invalid SOAP envelope"}} = Soap.parse(body)
    end

    test "reports a fault carrying an empty faultstring as a fault, not as success" do
      body = """
      <?xml version="1.0"?>
      <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP:Body><SOAP:Fault>
          <faultcode>SOAP:Server</faultcode>
          <faultstring></faultstring>
        </SOAP:Fault></SOAP:Body>
      </SOAP:Envelope>
      """

      assert {:error, {:soap_fault, _faultstring}} = Soap.parse(body)
    end

    test "returns an error rather than raising on malformed XML" do
      assert {:error, :malformed_xml} = Soap.parse("this is not xml <<<")
    end

    test "returns an error rather than expanding an entity declared in an internal DTD" do
      body = ~s(<?xml version="1.0"?><!DOCTYPE r [<!ENTITY a "x">]><r>&a;</r>)

      assert {:error, :malformed_xml} = Soap.parse(body)
    end

    test "refuses to fetch the external DTD a DOCTYPE points at" do
      # Without `dtd: :none` xmerl resolves the SYSTEM identifier and parses on;
      # a mailbox server must not get to name a resource this host will fetch.
      body = ~s(<?xml version="1.0"?><!DOCTYPE r SYSTEM "http://127.0.0.1:1/e.dtd"><r>hi</r>)

      assert {:error, :malformed_xml} = Soap.parse(body)
    end

    test "keeps the parser's quotation of the body out of the log" do
      # xmerl names the offending element in its own error reason, so inspecting
      # that reason lifts a fragment of the document into the log line. The
      # document is calendar data from the user's mailbox.
      LogCapture.attach()

      assert {:error, :malformed_xml} = Soap.parse("<a><PrivateMeetingSubject></a>")

      event = LogCapture.await_log("not parseable XML")

      refute LogCapture.dump(event) =~ "PrivateMeetingSubject"
    end

    test "returns an error rather than raising when the parser itself blows up" do
      # A malformed hexadecimal character reference raises out of xmerl instead
      # of taking its own fatal-error exit, which is what the `rescue` covers.
      assert {:error, :malformed_xml} = Soap.parse(~s(<?xml version="1.0"?><r>&#xZZ;</r>))
    end
  end

  describe "response_messages/2" do
    test "returns each response message element under the named response" do
      body = """
      <?xml version="1.0"?>
      <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP:Body>
          <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
            <m:ResponseMessages>
              <m:GetItemResponseMessage ResponseClass="Success">
                <m:ResponseCode>NoError</m:ResponseCode>
              </m:GetItemResponseMessage>
              <m:GetItemResponseMessage ResponseClass="Error">
                <m:ResponseCode>ErrorItemNotFound</m:ResponseCode>
              </m:GetItemResponseMessage>
            </m:ResponseMessages>
          </m:GetItemResponse>
        </SOAP:Body>
      </SOAP:Envelope>
      """

      {:ok, doc} = Soap.parse(body)
      messages = Soap.response_messages(doc, "GetItemResponseMessage")

      assert length(messages) == 2
      assert Soap.response_codes(messages) == ["NoError", "ErrorItemNotFound"]
    end

    test "matches on the namespace, not on the prefix the server happened to pick" do
      {:ok, doc} = Soap.parse(@renamed_prefixes)

      assert doc |> Soap.response_messages("GetItemResponseMessage") |> Soap.response_codes() ==
               ["NoError"]
    end

    test "ignores a same-named element sitting outside m:ResponseMessages" do
      body = """
      <?xml version="1.0"?>
      <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP:Body>
          <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
            <m:GetItemResponseMessage><m:ResponseCode>Stray</m:ResponseCode></m:GetItemResponseMessage>
            <m:ResponseMessages>
              <m:GetItemResponseMessage><m:ResponseCode>NoError</m:ResponseCode></m:GetItemResponseMessage>
            </m:ResponseMessages>
          </m:GetItemResponse>
        </SOAP:Body>
      </SOAP:Envelope>
      """

      {:ok, doc} = Soap.parse(body)

      assert doc |> Soap.response_messages("GetItemResponseMessage") |> Soap.response_codes() ==
               ["NoError"]
    end

    test "returns an empty list for a response message name the document does not carry" do
      {:ok, doc} = Soap.parse(@renamed_prefixes)

      assert Soap.response_messages(doc, "Unknown") == []
    end
  end

  describe "require_success/2" do
    test "returns every response message when all of them succeeded" do
      {:ok, doc} = Soap.parse(messages(["NoError", "NoError"]))

      assert {:ok, messages} = Soap.require_success(doc, "GetItemResponseMessage")
      assert Soap.response_codes(messages) == ["NoError", "NoError"]
    end

    test "surfaces the first stated failure rather than the messages" do
      # A failed message carries no payload, so reading past it answers the
      # empty list, which callers cannot tell from an empty mailbox.
      {:ok, doc} = Soap.parse(messages(["NoError", "ErrorAccessDenied"]))

      assert Soap.require_success(doc, "GetItemResponseMessage") ==
               {:error, {:response_code, "ErrorAccessDenied"}}
    end

    test "treats a message stating no response code as a failure" do
      {:ok, doc} = Soap.parse(messages([nil]))

      assert Soap.require_success(doc, "GetItemResponseMessage") == {:error, {:response_code, ""}}
    end

    test "reports a document carrying no such response message at all" do
      {:ok, doc} = Soap.parse(messages(["NoError"]))

      assert Soap.require_success(doc, "FindFolderResponseMessage") ==
               {:error, :no_response_messages}
    end
  end

  describe "response_code/1" do
    test "returns an empty string for a message carrying no ResponseCode" do
      body = """
      <?xml version="1.0"?>
      <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP:Body>
          <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
            <m:ResponseMessages>
              <m:GetItemResponseMessage ResponseClass="Success"/>
            </m:ResponseMessages>
          </m:GetItemResponse>
        </SOAP:Body>
      </SOAP:Envelope>
      """

      {:ok, doc} = Soap.parse(body)

      assert [message] = Soap.response_messages(doc, "GetItemResponseMessage")
      assert Soap.response_code(message) == ""
    end
  end

  describe "bind/1" do
    test "binds the EWS prefixes so a t:-prefixed path resolves under any prefix" do
      {:ok, doc} = Soap.parse(@renamed_prefixes)

      assert SweetXml.xpath(doc, Soap.bind(~x"//t:Subject/text()"s)) == "Standup"
      assert SweetXml.xpath(doc, Soap.bind(~x"//m:ResponseCode/text()"s)) == "NoError"
    end
  end

  describe "xpath/3" do
    test "binds the prefixes on the top-level spec" do
      {:ok, doc} = Soap.parse(@renamed_prefixes)

      assert Soap.xpath(doc, ~x"//t:Subject/text()"s) == "Standup"
    end

    test "binds the prefixes on subspecs, including nested ones" do
      {:ok, doc} = Soap.parse(@renamed_prefixes)

      assert Soap.xpath(
               doc,
               ~x"//m:GetItemResponseMessage"l,
               code: ~x"./m:ResponseCode/text()"s,
               item: [
                 ~x"./m:Items/t:CalendarItem",
                 subject: ~x"./t:Subject/text()"s
               ]
             ) == [%{code: "NoError", item: %{subject: "Standup"}}]
    end
  end

  # One `GetItem` response per code, `nil` meaning a message stating none.
  defp messages(codes) do
    payload =
      Enum.map_join(codes, "\n", fn
        nil ->
          ~s(<m:GetItemResponseMessage ResponseClass="Success"/>)

        code ->
          "<m:GetItemResponseMessage><m:ResponseCode>#{code}</m:ResponseCode></m:GetItemResponseMessage>"
      end)

    """
    <?xml version="1.0"?>
    <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
      <SOAP:Body>
        <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages">
          <m:ResponseMessages>#{payload}</m:ResponseMessages>
        </m:GetItemResponse>
      </SOAP:Body>
    </SOAP:Envelope>
    """
  end
end
