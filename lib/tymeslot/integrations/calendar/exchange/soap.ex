defmodule Tymeslot.Integrations.Calendar.Exchange.Soap do
  @moduledoc """
  SOAP envelope construction and response parsing for EWS.

  Deliberately free of EWS domain knowledge: it wraps a body, parses a
  response, surfaces SOAP faults, and hands back response-message elements.
  Which operations exist and what their payloads mean belongs to
  `Exchange.Requests` and the normaliser modules.

  Parsing goes through SweetXml with entity expansion disabled and namespace
  conformance on, matching the posture `CalDAV.XmlHandler` takes for the same
  reason: the XML on this path comes from a server the user nominated, so it is
  not trusted input.
  """

  import SweetXml

  require Logger

  @types_ns "http://schemas.microsoft.com/exchange/services/2006/types"
  @messages_ns "http://schemas.microsoft.com/exchange/services/2006/messages"
  @soap_ns "http://schemas.xmlsoap.org/soap/envelope/"

  # Exchange 2013 is the lowest schema version carrying everything this
  # provider uses, and every supported on-premises server (2016, 2019, SE)
  # accepts it. Naming a newer version would exclude older servers for no gain.
  @server_version "Exchange2013"

  @namespaces [t: @types_ns, m: @messages_ns, s: @soap_ns]

  @doc "Wraps a request body in a SOAP envelope with the EWS version header."
  @spec envelope(String.t()) :: String.t()
  def envelope(body) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <soap:Envelope xmlns:soap="#{@soap_ns}"
                   xmlns:t="#{@types_ns}"
                   xmlns:m="#{@messages_ns}">
      <soap:Header><t:RequestServerVersion Version="#{@server_version}"/></soap:Header>
      <soap:Body>#{body}</soap:Body>
    </soap:Envelope>
    """
  end

  @doc """
  Parses a SOAP response body.

  Returns `{:error, {:soap_fault, message}}` when the server answered a fault,
  and `{:error, :malformed_xml}` when the body is not XML at all. A fault is a
  normal outcome on this path (EWS answers one for a malformed request), so it
  is a typed error rather than an exception.
  """
  @spec parse(String.t()) :: {:ok, tuple()} | {:error, {:soap_fault, String.t()} | :malformed_xml}
  def parse(body) when is_binary(body) do
    # `namespace_conformant: true` is load-bearing, not defensive. Without it
    # xmerl matches an xpath prefix against the literal prefix in the document,
    # so `//m:GetItemResponseMessage` would silently return `[]` for any server
    # that binds the messages namespace to a prefix other than `m`. With it,
    # names are compared by namespace URI and the prefix stops mattering.
    doc = SweetXml.parse(body, quiet: true, dtd: :none, namespace_conformant: true)

    case xpath(doc, add_namespace(~x"//s:Fault/faultstring/text()"s, :s, @soap_ns)) do
      "" -> {:ok, doc}
      fault -> {:error, {:soap_fault, fault}}
    end
  rescue
    error -> malformed_xml(error)
  catch
    # xmerl signals a fatal parse error by exiting rather than by raising, so
    # both escape routes have to be covered to keep this a typed error.
    :exit, reason -> malformed_xml(reason)
  end

  @doc "Returns every response-message element of the given local name."
  @spec response_messages(tuple(), String.t()) :: [tuple()]
  def response_messages(doc, message_name) do
    xpath(doc, message_path(message_name))
  end

  @doc "Returns the `ResponseCode` text of each given response message."
  @spec response_codes([tuple()]) :: [String.t()]
  def response_codes(messages) do
    Enum.map(messages, &response_code/1)
  end

  @doc "Returns the `ResponseCode` text of one response message."
  @spec response_code(tuple()) :: String.t()
  def response_code(message) do
    xpath(message, add_namespace(~x"./m:ResponseCode/text()"s, :m, @messages_ns))
  end

  @doc "The namespace bindings callers pass to their own xpath expressions."
  @spec namespaces() :: keyword()
  def namespaces, do: @namespaces

  # The body itself is never logged: it is calendar data from the user's mailbox.
  defp malformed_xml(cause) do
    Logger.warning("Exchange SOAP response is not parseable XML", error: inspect(cause))

    {:error, :malformed_xml}
  end

  defp message_path(message_name) do
    "//m:#{message_name}"
    |> SweetXml.sigil_x(~c"l")
    |> add_namespace(:m, @messages_ns)
  end
end
