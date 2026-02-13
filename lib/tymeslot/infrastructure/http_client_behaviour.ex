defmodule Tymeslot.Infrastructure.HTTPClientBehaviour do
  @moduledoc """
  Behaviour for HTTPClient to enable mocking in tests.
  Uses Req for HTTP requests.
  """

  @callback get(String.t(), list(), keyword()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}
  @callback post(String.t(), any(), list(), keyword()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}
  @callback put(String.t(), any(), list(), keyword()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}
  @callback delete(String.t(), list(), keyword()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}
  @callback head(String.t(), list(), keyword()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}
  @callback report(String.t(), any(), list(), keyword()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}
  @callback request(atom() | String.t(), String.t(), any(), list(), keyword()) ::
              {:ok, Req.Response.t()} | {:error, Exception.t()}
end
