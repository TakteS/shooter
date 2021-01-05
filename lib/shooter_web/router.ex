defmodule ShooterWeb.Router do
  use ShooterWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {ShooterWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ShooterWeb do
    pipe_through :browser

    get "/", LobbyController, :index
    get "/lobby/:session_id", LobbyController, :index
    post "/", LobbyController, :create

    live "/game/:session_id", GameLive, :index
  end
end
