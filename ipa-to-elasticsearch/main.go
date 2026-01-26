package main

import (
	"context"
	"crypto/tls"
	"encoding/csv"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/italia/developers-italia-backend/crawler/elastic"
	es "github.com/olivere/elastic/v7"
	log "github.com/sirupsen/logrus"
)

// UpdateFromIndicePA downloads the pec.txt file and loads it into Elasticsearch.
func UpdateFromIndicePA(elasticClient *es.Client) error {
	type amministrazioneES struct {
		IPA         string `json:"ipa"`
		Description string `json:"description"`
		Type        string `json:"type"`
		PEC         string `json:"pec"`
	}

	// Read the PEC CSV file
	lines, err := readCSV("pec.txt")
	if err != nil {
		return err
	}

	// Loop through the PEC addresses, retrieve the template record for each entity
	// and add the PEC address to each one.
	var records []amministrazioneES

	// Skip header
	for _, line := range lines[1:] {
		records = append(records, amministrazioneES{
			IPA:         strings.ToLower(line[0]),
			Description: line[1],
			Type:        line[3],
			PEC:         line[7],
		})
	}

	if len(records) == 0 {
		return fmt.Errorf("0 PEC addresses read from IndicePA; aborting")
	}

	log.Debugf("inserting %d records into Elasticsearch", len(records))

	// Delete existing index if exists
	// TODO: use an alias for atomic updates!
	ctx := context.Background()
	_, err = elasticClient.DeleteIndex("indicepa_pec").Do(ctx)
	if err != nil && !es.IsNotFound(err) {
		return err
	}

	// Create mapping if it does not exist
	err = elastic.CreateIndexMapping("indicepa_pec", elastic.IPAMapping, elasticClient)
	if err != nil {
		return err
	}

	// Perform a bulk request to Elasticsearch
	bulkRequest := elasticClient.Bulk()
	for n, amm := range records {
		req := es.NewBulkIndexRequest().
			Index("indicepa_pec").
			Id(strconv.Itoa(n)).
			Doc(amm)
		bulkRequest.Add(req)
	}
	bulkResponse, err := bulkRequest.Do(ctx)
	if err != nil {
		return err
	}

	log.Infof("%d records indexed from IndicePA", len(bulkResponse.Indexed()))

	return nil
}

func readCSV(file string) ([][]string, error) {
	f, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	// Read the CSV file
	reader := csv.NewReader(f)
	reader.Comma = '\t'
	reader.ReuseRecord = true
	reader.LazyQuotes = true
	return reader.ReadAll()
}

// Not used because of https://github.com/golang/go/issues/15196
// (indicepa.gov.it's certificate uses DirectoryName name constraints)
func _readCSVFromURL(url string) ([][]string, error) {
	// disable HTTP/2 because IndicePA does not support it
	tr := &http.Transport{
		TLSNextProto: make(map[string]func(authority string, c *tls.Conn) http.RoundTripper),
	}
	client := &http.Client{Transport: tr}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}

	reader := csv.NewReader(resp.Body)
	reader.Comma = '\t'
	reader.ReuseRecord = true
	reader.LazyQuotes = true
	return reader.ReadAll()
}

func main() {
	es, err := elastic.ClientFactory(
		os.Getenv("ELASTIC_URL"),
		os.Getenv("ELASTIC_USER"),
		os.Getenv("ELASTIC_PWD"))
	if err != nil {
		log.Fatal(err)
	}

	err = UpdateFromIndicePA(es)
	if err != nil {
		log.Fatal(err)
	}
}
