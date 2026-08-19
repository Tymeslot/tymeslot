defmodule Tymeslot.Integrations.Calendar.Exchange.SoapTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  describe "envelope/1" do
    test "wraps a body in a SOAP envelope carrying the Exchange2013 version header" do
      xml = Soap.envelope("<m:GetFolder/>")

      assert xml =~ ~s(<soap:Envelope)
      assert xml =~ ~s(xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types")
      assert xml =~ ~s(xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages")
      assert xml =~ ~s(<t:RequestServerVersion Version="Exchange2013"/>)
      assert xml =~ "<m:GetFolder/>"
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

    test "returns an error rather than raising on malformed XML" do
      assert {:error, :malformed_xml} = Soap.parse("this is not xml <<<")
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
      body = """
      <?xml version="1.0"?>
      <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        <s:Body>
          <q:GetItemResponse xmlns:q="http://schemas.microsoft.com/exchange/services/2006/messages">
            <q:ResponseMessages>
              <q:GetItemResponseMessage ResponseClass="Success">
                <q:ResponseCode>NoError</q:ResponseCode>
              </q:GetItemResponseMessage>
            </q:ResponseMessages>
          </q:GetItemResponse>
        </s:Body>
      </s:Envelope>
      """

      {:ok, doc} = Soap.parse(body)
      messages = Soap.response_messages(doc, "GetItemResponseMessage")

      assert Soap.response_codes(messages) == ["NoError"]
    end
  end

  describe "namespaces/0" do
    test "returns the bindings callers thread into their own xpath expressions" do
      assert Soap.namespaces() == [
               t: "http://schemas.microsoft.com/exchange/services/2006/types",
               m: "http://schemas.microsoft.com/exchange/services/2006/messages",
               s: "http://schemas.xmlsoap.org/soap/envelope/"
             ]
    end
  end
end
