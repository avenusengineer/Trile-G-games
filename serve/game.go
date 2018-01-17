package main

import (
"io/ioutil"
	"log"
	"net/http"
	"sync"

	"github.com/golang/protobuf/proto"
	"github.com/gorilla/websocket"

	pb "gitlab.com/rrrob/triples/serve/proto"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
}

type Games struct {
	mu    sync.Mutex
	games map[string]*Game
}

func newGames() *Games {
	return &Games{
		games: map[string]*Game{},
	}
}

func (g *Games) Get(blob Blob) *Game {
	key := blob.ChatInstance
	g.mu.Lock()
	defer g.mu.Unlock()
	game := g.games[key]
	if game != nil {
		return game
	}
	g.games[key] = newGame(blob)
	return g.games[key]
}

type Game struct {
	creator Blob
}

func newGame(blob Blob) *Game {
	g := &Game{
		creator: blob,
	}
	go g.loop()
	return g
}

func (g *Game) loop() {
	log.Printf("starting new game: %s %s", g.creator.Game, g.creator.FirstName)
}

func (g *Game) join(b Blob) (pb.Update, <-chan pb.Update) {
	log.Printf("player joining: %s", b.FirstName)
	return pb.Update{}, make(chan pb.Update)
}

func (g *Game) claim(c pb.Claim) {
}

func (g *Game) Serve(b Blob, w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("websocket upgrade: %s", err)
		return
	}
	defer conn.Close()

	claims := make(chan pb.Claim)
	go func() {
		defer close(claims)
		for {
			t, m, err := conn.NextReader()
			if err != nil {
				log.Printf("conn err: %s", err)
				return
			}
			switch t {
			case websocket.TextMessage:
				bs, err := ioutil.ReadAll(m)
				if err != nil {
					log.Printf("reading message: %s", err)
					return
				}
				claim := pb.Claim{}
				if err := proto.Unmarshal(bs, &claim); err != nil {
					log.Printf("proto err: %s", err)
					return
				}
				claims <- claim
			default:
				log.Printf("ignoring message type: %d", t)
			}
		}
	}()

	writeUpdate := func(u pb.Update) error {
		w, err := conn.NextWriter(websocket.TextMessage)
		if err != nil {
			return err
		}
		defer w.Close()
		b, err := proto.Marshal(&u)
		if err != nil {
			return err
		}
		_, err = w.Write(b)
		return err
	}

	welcome, updates := g.join(b)
	if err := writeUpdate(welcome); err != nil {
		log.Print(err)
		return
	}
	for {
		select {
		case u := <-updates:
			if err := writeUpdate(u); err != nil {
				log.Print(err)
				return
			}
		case c := <-claims:
			g.claim(c)
		}
	}
}
