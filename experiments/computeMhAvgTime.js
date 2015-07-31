var fs = require('fs');
var assert = require('assert');


function main(infile, outfile) {
	var contents = fs.readFileSync(infile).toString();
	var lines = contents.split('\n');
	assert(lines[0] === 'method,numSamps,time,avgScore,maxScore');
	lines = lines.slice(1);

	// Compute average MH time for each numSamps
	var avgtimes = {};
	var numRows = {};
	for (var i = 0; i < lines.length; i++) {
		var line = lines[i];
		var toks = line.split(',');
		var method = toks[0];
		var numSamps = toks[1];
		if (method === 'mh') {
			var time = parseFloat(toks[2]);
			if (avgtimes[numSamps] === undefined) {
				avgtimes[numSamps] = 0.0;
				numRows[numSamps] = 0;
			}
			avgtimes[numSamps] += time;
			numRows[numSamps] += 1;
		}
	}
	for (var numSamps in avgtimes) {
		avgtimes[numSamps] /= numRows[numSamps];
	}

	// Write a new file that contains these data
	var f = fs.openSync(outfile, 'w');
	fs.writeSync(f, 'method,numSamps,time,avgScore,maxScore,MHavgTime\n');
	for (var i = 0; i < lines.length; i++) {
		var line = lines[i];
		var toks = line.split(',');
		var numSamps = toks[1];
		fs.writeSync(f, line + ',' + avgtimes[numSamps] + '\n');
	}
	fs.closeSync(f);
}

if (process.argv.length < 4) {
	console.log('usage: node computeMhAvgTime infile outfile');
	process.exit(1);
}
main(process.argv[2], process.argv[3]);