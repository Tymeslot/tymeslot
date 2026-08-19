defmodule Tymeslot.Integrations.Calendar.Exchange.Soap do
  @moduledoc """
  SOAP envelope construction and response parsing for EWS.

  Deliberately free of EWS domain knowledge: it wraps a body, parses a
  response, surfaces SOAP faults, and hands back response-message elements.
  Which operations exist and what their payloads mean belongs to
  `Exchange.Requests` and the normaliser modules.

  The XML on this path comes from a server the user nominated, so it is not
  trusted input. Parsing therefore runs with `dtd: :none`, which refuses to
  fetch an external DTD (xmerl would otherwise resolve a `SYSTEM` identifier
  in a `DOCTYPE`), and with namespace conformance on. Entity declarations are
  refused by xmerl itself, so no expansion is possible either way.

  Unlike `CalDAV.XmlHandler`, this module applies no size cap of its own. EWS
  bodies reach it through `Tymeslot.Infrastructure.HTTPClient`, which streams
  every response through a byte budget (`:max_response_bytes`) and aborts the
  transfer once it is exceeded, so the size bound is already enforced at the
  transport layer.

  Callers extract values with `xpath/2,3` here rather than with
  `SweetXml.xpath/2,3`, because this one binds the `t:`, `m:` and `s:`
  prefixes onto the expression and onto every subspec. SweetXml offers no
  document-level namespace option: bindings live on the expression itself, and
  each subspec carries its own, so an unbound prefix in a nested extraction
  yields `""` rather than an error.
  """

  import SweetXml, except: [xpath: 2, xpath: 3]

  require Logger

  @typedoc """
  A parsed XML node: the document root returned by `parse/1`, or any element
  within it. An `xmlElement` record, opaque to callers beyond `xpath/2,3`.
  """
  @type document :: tuple()

  @typedoc "An xpath expression, as built by SweetXml's `~x` sigil."
  @type xpath_spec :: %SweetXpath{}

  @types_ns "http://schemas.microsoft.com/exchange/services/2006/types"
  @messages_ns "http://schemas.microsoft.com/exchange/services/2006/messages"
  @soap_ns "http://schemas.xmlsoap.org/soap/envelope/"

  # Exchange 2013 is the lowest schema version carrying everything this
  # provider uses, and every supported on-premises server (2016, 2019, SE)
  # accepts it. Naming a newer version would exclude older servers for no gain.
  @server_version "Exchange2013"

  @namespaces [t: @types_ns, m: @messages_ns, s: @soap_ns]

  @doc """
  Wraps a request body in a SOAP envelope with the EWS version header.

  `body` is interpolated verbatim, so the caller owns its well-formedness and
  any escaping its values need. That is deliberate: callers pass an XML
  fragment they built, not text to be escaped.
  """
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

  A body that is not XML at all is logged as an anomaly. Pass `log: false`
  where it is not one: a caller that classifies the response by its HTTP status
  regardless (EWS answers a 500 with an IIS or reverse-proxy error page as a
  matter of course) would otherwise leave the operator reading a parse warning
  that describes a status failure.
  """
  @spec parse(String.t(), keyword()) ::
          {:ok, document()} | {:error, {:soap_fault, String.t()} | :malformed_xml}
  def parse(body, opts \\ []) when is_binary(body) do
    with {:ok, doc} <- parse_document(body, opts) do
      # The fault element is detected before its text is read: a fault whose
      # `faultstring` is empty is still a fault, and reading the text first
      # would make it indistinguishable from no fault at all.
      case xpath(doc, ~x"//s:Fault"o) do
        nil -> {:ok, doc}
        fault -> {:error, {:soap_fault, SweetXml.xpath(fault, ~x"./faultstring/text()"s)}}
      end
    end
  end

  @doc "Returns every response message of the given local name."
  @spec response_messages(document(), String.t()) :: [document()]
  def response_messages(doc, message_name) do
    xpath(doc, ~x"//m:ResponseMessages/m:#{message_name}"l)
  end

  @doc "Returns the `ResponseCode` text of each given response message."
  @spec response_codes([document()]) :: [String.t()]
  def response_codes(messages) do
    Enum.map(messages, &response_code/1)
  end

  @doc """
  Returns the `ResponseCode` text of one response message.

  A message carrying no `m:ResponseCode` yields `""`, as does one carrying an
  empty element. The two are not distinguished, and need not be: `""` is not a
  valid EWS response code either way, so both mean "this message stated no
  outcome" and callers can treat them as one case.
  """
  @spec response_code(document()) :: String.t()
  def response_code(message) do
    xpath(message, ~x"./m:ResponseCode/text()"s)
  end

  @doc "Binds the EWS prefixes (`t:`, `m:`, `s:`) onto an xpath expression."
  @spec bind(xpath_spec()) :: xpath_spec()
  def bind(%SweetXpath{} = expr) do
    Enum.reduce(@namespaces, expr, fn {prefix, uri}, acc -> add_namespace(acc, prefix, uri) end)
  end

  @doc """
  `SweetXml.xpath/3` with the EWS prefixes bound on the spec and every subspec.

  Subspecs nest: a value of `[expression, key: expression]` is descended into,
  so every expression in the tree is bound however deep it sits.
  """
  @spec xpath(document(), xpath_spec(), keyword()) :: term()
  def xpath(node, spec, subspecs \\ []) do
    SweetXml.xpath(node, bind(spec), bind_subspecs(subspecs))
  end

  defp bind_subspecs(subspecs) do
    Enum.map(subspecs, fn {key, value} -> {key, bind_subspec(value)} end)
  end

  defp bind_subspec(%SweetXpath{} = expr), do: bind(expr)
  defp bind_subspec([%SweetXpath{} = expr | nested]), do: [bind(expr) | bind_subspecs(nested)]

  # Only the parse itself is guarded: widening the guards over the fault xpath
  # would report a bug there as `:malformed_xml`.
  defp parse_document(body, opts) do
    {:ok, SweetXml.parse(body, quiet: true, dtd: :none, namespace_conformant: true)}
  rescue
    # Most malformed input leaves through the `catch` below, but not all of
    # it: xmerl raises on some, a malformed hexadecimal character reference
    # (`&#xZZ;`) among them.
    error -> malformed_xml(error, opts)
  catch
    # xmerl signals a fatal parse error by exiting rather than by raising, so
    # both escape routes have to be covered to keep this a typed error.
    :exit, reason -> malformed_xml(reason, opts)
  end

  defp malformed_xml(cause, opts) do
    if Keyword.get(opts, :log, true) do
      Logger.warning("Exchange SOAP response is not parseable XML", error: cause_label(cause))
    end

    {:error, :malformed_xml}
  end

  # The body itself is never logged: it is calendar data from the user's
  # mailbox. Nor is the parser's reason term, which quotes it: an unmatched end
  # tag arrives as `{:endtag_does_not_match, {:was, :a, :should_have_been,
  # :Leaked}}`, naming an element out of the document. Only the shape of the
  # failure and where it happened survive, and neither can carry input.
  defp cause_label({:fatal, {reason, _file, {:line, line}, {:col, column}}}),
    do: "#{failure_tag(reason)} at line #{line}, column #{column}"

  defp cause_label(%FunctionClauseError{module: module, function: function, arity: arity}),
    do: "no function clause in #{inspect(module)}.#{function}/#{arity}"

  defp cause_label(%module{}), do: inspect(module)
  defp cause_label(_other), do: "unrecognised parse failure"

  defp failure_tag(reason) when is_atom(reason), do: reason

  defp failure_tag(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: failure_tag(elem(reason, 0))

  defp failure_tag(_reason), do: :unknown
end
