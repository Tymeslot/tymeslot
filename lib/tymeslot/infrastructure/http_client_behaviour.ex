defmodule Tymeslot.Infrastructure.HTTPClientBehaviour do
  @moduledoc """
  Behaviour for HTTPClient to enable mocking in tests.
  """

  @callback get(String.t(), list(), keyword()) ::
              {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  @callback post(String.t(), any(), list(), keyword()) ::
              {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  @callback put(String.t(), any(), list(), keyword()) ::
              {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  @callback delete(String.t(), list(), keyword()) ::
              {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  @callback request(atom() | String.t(), String.t(), any(), list(), keyword()) ::
              {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
end
