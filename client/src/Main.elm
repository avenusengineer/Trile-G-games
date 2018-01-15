module Main exposing (..)

import Card exposing (..)
import Debug
import Dict
import Game exposing (Game)
import Graphics
import Graphics.Style as Style
import Html
import Html.Attributes as HtmlA
import Html.Events as HtmlE
import Http
import List.Extra
import Menu
import Navigation
import Play
import Process
import Random
import Svg
import Svg.Attributes as SvgA
import Svg.Events as SvgE
import Task
import Time
import UrlParser exposing ((<?>))


main =
    Navigation.program (always Ignore)
        { init = init
        , view = view
        , update = update
        , subscriptions = \_ -> Sub.none
        }


type alias Model =
    { params : Params
    , page : Page
    }


type Page
    = Menu Menu.Model
    | Play Play.Model


type alias Params =
    { style : Style.Style
    , key : Maybe String
    , name : Maybe String
    }


init : Navigation.Location -> ( Model, Cmd Msg )
init loc =
    ( { params = parseParams loc
      , page = Menu Nothing
      }
    , Cmd.none
    )


view : Model -> Html.Html Msg
view model =
    Html.div [ HtmlA.id "container", HtmlA.style [ ( "background", model.params.style.colors.table ) ] ]
        [ case model.page of
            Menu msg ->
                viewStart model.params.name model.params.style msg

            Play game ->
                Html.map (\m -> GetTimeAndThen (PlayMsg m)) <| Play.view model.params.style game
        ]


viewStart : Maybe String -> Style.Style -> Maybe String -> Html.Html Msg
viewStart name style score =
    let
        addScore h =
            case score of
                Just m ->
                    Html.div [ HtmlA.class "msg", HtmlA.style [ ( "background", snd style.colors.symbols ) ] ] [ Html.text m ] :: h

                Nothing ->
                    h

        prompt =
            "Choose a game"
                ++ (case name of
                        Just n ->
                            ", " ++ n ++ "!"

                        Nothing ->
                            "!"
                   )

        fst ( x, y, z ) =
            x

        snd ( x, y, z ) =
            y

        trd ( x, y, z ) =
            z
    in
    Html.div [ HtmlA.id "main" ] <|
        addScore
            [ Html.div
                [ HtmlA.class "msg", HtmlA.style [ ( "background", trd style.colors.symbols ) ] ]
                [ Html.text prompt ]
            , Html.div [ HtmlA.class "buttons" ]
                [ Html.button [ HtmlE.onClick <| Go False False ] [ Html.text "Classic (scored!)" ]
                , Html.button [ HtmlE.onClick <| Go True False ] [ Html.text "Classic (short)" ]
                , Html.button [ HtmlE.onClick <| Go False True ] [ Html.text "Super" ]
                , Html.button [ HtmlE.onClick <| Go True True ] [ Html.text "Super (short)" ]
                ]
            ]


after : Time.Time -> (Time.Time -> Msg) -> Cmd Msg
after time msg =
    let
        task =
            Time.now
                |> Task.andThen
                    (\now ->
                        Process.sleep time
                            |> Task.andThen (\_ -> Task.succeed now)
                    )
    in
    Task.perform msg task


type Msg
    = Go Bool Bool
    | NewGame Game
    | GetTimeAndThen (Time.Time -> Msg)
    | PlayMsg Play.Msg Time.Time
    | Ignore
    | APIResult (Result Http.Error String)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        APIResult r ->
            let
                _ =
                    Debug.log "api result" r
            in
            ( model, Cmd.none )

        Ignore ->
            ( model, Cmd.none )

        GetTimeAndThen m ->
            ( model, Task.perform m Time.now )

        Go short super ->
            ( model, Cmd.batch [ Random.generate NewGame (Game.init short super), Task.perform (PlayMsg Play.StartGame) Time.now ] )

        NewGame game ->
            ( { model | page = Play (Play.init game) }, Cmd.none )

        PlayMsg pmsg now ->
            let
                pmodel =
                    case model.page of
                        Play pm ->
                            pm

                        _ ->
                            Debug.crash "bad state"

                ( newpmodel, res ) =
                    Play.update now pmsg pmodel
            in
            case res of
                Nothing ->
                    ( { model | page = Play newpmodel }, Cmd.none )

                Just (Play.After delay m) ->
                    ( { model | page = Play newpmodel }, after delay (PlayMsg m) )

                Just (Play.GameOver log) ->
                    let
                        ( secs, msg, telescore ) =
                            score log

                        scored =
                            case model.page of
                                Menu _ ->
                                    False

                                Play g ->
                                    g.game.type_ == Game.ClassicSet && not g.game.short

                        send =
                            if scored then
                                case model.params.key of
                                    Just k ->
                                        sendScore k telescore

                                    _ ->
                                        Cmd.none
                            else
                                Cmd.none
                    in
                    ( { model | page = Menu (Just msg) }, send )


parseParams : Navigation.Location -> Params
parseParams loc =
    let
        parser =
            UrlParser.top
                <?> UrlParser.stringParam "style"
                <?> UrlParser.stringParam "key"
                <?> UrlParser.stringParam "name"

        f s k n =
            { style =
                case Maybe.withDefault "square" s of
                    "classic" ->
                        Style.classic

                    "modified" ->
                        Style.modified

                    _ ->
                        Style.square
            , key = k
            , name = n
            }
    in
    case UrlParser.parseHash (UrlParser.map f parser) loc of
        Nothing ->
            Debug.crash "url parse failure"

        Just p ->
            p


sendScore : String -> Int -> Cmd Msg
sendScore key score =
    Http.send APIResult <|
        Http.getString <|
            "https://arp.vllmrt.net/triples/api/win?key="
                ++ key
                ++ "&score="
                ++ toString score


score : List ( Time.Time, Play.Event ) -> ( Int, String, Int )
score log =
    let
        end =
            Maybe.withDefault 0 <| Maybe.map Tuple.first <| List.head <| log

        start =
            Maybe.withDefault 0 <| Maybe.map Tuple.first <| List.head <| List.reverse <| log

        secs =
            round <| Time.inSeconds (end - start)

        format secs =
            let
                m =
                    secs // 60

                s =
                    secs % 60
            in
            toString m ++ ":" ++ (String.padLeft 2 '0' <| toString s)

        baddeals =
            List.length <| List.filter (Tuple.second >> (==) Play.EDealMoreNonzero) <| log

        gooddeals =
            List.length <| List.filter (Tuple.second >> (==) Play.EDealMoreZero) <| log

        baddealsecs =
            baddeals * 60

        gooddealsecs =
            gooddeals * 45

        totalsecs =
            secs + baddealsecs - gooddealsecs
    in
    ( totalsecs
    , String.join " " [ "Your time:", format totalsecs, "=", format secs, "+", format baddealsecs, "-", format gooddealsecs ]
    , 10000 // totalsecs
    )
