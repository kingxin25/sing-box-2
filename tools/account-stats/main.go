package main

import (
	"context"
	"fmt"
	"os"
	"regexp"
	"time"

	v2rayapi "github.com/sagernet/sing-box/experimental/v2rayapi"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	if len(os.Args) != 2 || !regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`).MatchString(os.Args[1]) {
		fmt.Fprintln(os.Stderr, "usage: account-stats <inbound-tag>")
		os.Exit(2)
	}
	conn, err := grpc.NewClient("127.0.0.1:12080", grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	pattern := `^inbound>>>` + regexp.QuoteMeta(os.Args[1]) + `>>>traffic>>>`
	result, err := v2rayapi.NewStatsServiceClient(conn).QueryStats(ctx, &v2rayapi.QueryStatsRequest{
		Patterns: []string{pattern},
		Regexp:   true,
		Reset_:   true,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var total int64
	for _, stat := range result.GetStat() {
		if stat.GetValue() > 0 {
			total += stat.GetValue()
		}
	}
	fmt.Println(total)
}
