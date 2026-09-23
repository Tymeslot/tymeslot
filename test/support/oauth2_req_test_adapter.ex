defmodule Tymeslot.Test.OAuth2ReqTestAdapter do
  @moduledoc """
  Tesla adapter that hands the `oauth2` library's requests to `Req.Test`.

  Sign-in OAuth goes through the `oauth2` library, which speaks Tesla, while
  every other outbound request in the app goes through Req. Routing both into
  the same `Req.Test` stub (`:tymeslot_http`) lets a test script a provider
  once, whichever HTTP stack is on the other side of it.
  """

  @behaviour Tesla.Adapter

  @impl Tesla.Adapter
  def call(%Tesla.Env{} = env, _opts) do
    case Req.request(
           method: env.method,
           url: Tesla.build_url(env),
           headers: env.headers,
           body: env.body || "",
           plug: {Req.Test, :tymeslot_http},
           retry: false,
           decode_body: false
         ) do
      {:ok, response} ->
        headers = for {name, values} <- response.headers, value <- values, do: {name, value}
        {:ok, %{env | status: response.status, headers: headers, body: response.body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
