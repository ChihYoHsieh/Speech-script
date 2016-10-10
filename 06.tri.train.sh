#!/bin/bash

if [ -f setup.sh ]; then
  . setup.sh;
else
  echo "ERROR: setup.sh is missing!";
  exit 1;
fi

dir=exp/tri
srcdir=exp/mono
treedir=exp/tree
feat=$train_feat_setup

[ ! -f $srcdir/final.mdl ] && echo "$srcdir/final.mdl is required in the training process , aborting ..." && exit 1
[ ! -f $srcdir/train.ali ] && echo "$srcdir/train.ali is required in the training process , aborting ..." && exit 1
[ ! -f $treedir/tree ] && echo "$treedir/tree is required in the training process , aborting ..." && exit 1

num_pdfs=`head -n 1 <(tree-info $treedir/tree 2> /dev/null | awk '{ print $2 }')`
realign_iters="10 20 30";
numiters=35    # Number of iterations of training
maxiterinc=25  # Last iter to increase #Gauss on.
numgauss=$num_pdfs
totgauss=$[$num_pdfs * 5]
incgauss=$[($totgauss-$numgauss)/$maxiterinc] # per-iter increment for #Gauss
scale_opts="--transition-scale=1.0 --acoustic-scale=0.1 --self-loop-scale=0.1"

mkdir -p $dir
mkdir -p $dir/log

echo "Using [ $treedir/tree ] as senone clustering tree"
cp $treedir/tree $dir/tree

echo "Initializing triphone system"
if [ ! -f $dir/00.mdl ]; then
  log=$dir/log/tri.init.log
  echo "    output -> $dir/00.mdl $dir/00.occs"
  echo "    log -> $log"
  gmm-init-model --write-occs=$dir/00.occs $treedir/tree \
    $treedir/tree.acc train/topo $dir/00.mdl \
    2> $log
else
  echo "    $dir/00.mdl exists , skipping ..."
fi

iter=0
x=`printf "%02g" $iter`
y=`printf "%02g" $[$iter+1]`

echo "Iteration 00 :"
echo "    split to [ $numgauss ] Gaussians"
if [ ! -f $dir/01.mdl ]; then
  log=$dir/log/mixup.log
  echo "        output -> $dir/01.mdl"
  echo "        log -> $log"
  gmm-mixup --mix-up=$numgauss $dir/00.mdl $dir/00.occs $dir/01.mdl 2> $log
else
  echo "        $dir/01.mdl exists , skipping ..."
fi
echo "    converting alignments"
if [ ! -f $dir/00.ali ] || [ ! -f $dir/log/done.00.ali ]; then
  log=$dir/log/convert.ali.log
  echo "        output-> $dir/00.ali"
  echo "        log -> $log"
  convert-ali $srcdir/final.mdl $dir/01.mdl $dir/tree \
    ark:$srcdir/train.ali ark:$dir/00.ali 2> $log
  touch $dir/log/done.00.ali
else
  echo "        $dir/00.ali exists , skipping ..."
fi
ln -sf 00.ali $dir/train.ali

echo "    compiling training graphs"
if [ ! -f $dir/train.graph ] || [ ! -f $dir/log/done.graph ]; then
  log=$dir/log/compile.graphs.log
  echo "        output -> $dir/train.graph"
  echo "        log -> $log"
  compile-train-graphs $dir/tree $dir/01.mdl train/L.fst \
    ark:train/train.int ark:$dir/train.graph 2> $log
  touch $dir/log/done.graph
else
  echo "        $dir/train.graph exists , skipping ..."
fi

# TODO: complete the iterative training part


beam=10
for (( iter=1; $iter<$numiters; iter=$iter+1 ))
do

	x=`printf "%02g" $iter`
	y=`printf "%02g" $[$iter+1]`

	echo "Iteration $x :"
    if echo $realign_iters | grep -w $iter >/dev/null ; then
	 
	  echo "    re-aligning training graphs "
	  if [ ! -f $dir/log/done.$x.ali ] || [ ! -f $dir/$x.ali ]; then
	    log=$dir/log/align.$x.log
	    echo "        output -> $dir/$x.ali"
	    echo "        log -> $log"
	 
	    gmm-align-compiled $scale_opts --beam=$beam --retry-beam=$[$beam*4] \
		 $dir/$x.mdl ark:$dir/train.graph "ark,s,cs:$feat" ark:$dir/$x.ali 2> $log
		ln -sf $x.ali $dir/train.ali
	 
	    touch $dir/log/done.$x.ali
	  else
	    echo "        $dir/$x.ali exists , skipping ..."
	  fi
	
	fi
	

	echo "    accumulating GMM statistics"
	if [ ! -f $dir/$x.acc ]; then
	  log=$dir/log/acc.$x.log
	  echo "        output -> $dir/$x.acc"
	  echo "        log -> $log"
	  gmm-acc-stats-ali --binary=false $dir/$x.mdl "ark,s,cs:$feat" \
		ark:$dir/train.ali $dir/$x.acc 2> $log
	else
	  echo "        $dir/$x.acc exists , skipping ..."
	fi

	echo "    updating GMM parameters and splitting to [ $numgauss ] gaussians"
	if [ ! -f $dir/$y.mdl ]; then
	  log=$dir/log/update.$x.log
	  echo "        output -> $dir/$y.mdl"
	  echo "        log -> $log"
	  gmm-est --binary=false --write-occs=$dir/$y.occs --min-gaussian-occupancy=3 --mix-up=$numgauss \
		$dir/$x.mdl $dir/$x.acc $dir/$y.mdl 2> $log
	else
	  echo "        $dir/$y.mdl exists , skipping ..."
	fi
	
	if [ $iter -le $maxiterinc ]; then
		numgauss=$[$numgauss+$incgauss]
	fi 
done

echo "Training completed:"
echo "     mdl = $dir/final.mdl"
echo "    occs = $dir/final.occs"
echo "    tree = $dir/tree"
cp -f $dir/$y.mdl $dir/final.mdl
cp -f $dir/$y.occs $dir/final.occs

echo "Cleaning redundant materials generated during training process"
rm -f $dir/train.graph
ali=`readlink $dir/train.ali`
rm -f $dir/train.ali
cp -f $dir/$ali $dir/train.ali
rm -f $dir/00.*
iter=1
while [ $iter -le $numiters ]; do
  x=`printf "%02g" $iter`
  y=`printf "%02g" $[$iter+1]`
  rm -f $dir/$x.* $dir/$y.*
  iter=$[$iter+1];
done

#

sec=$SECONDS

echo ""
echo "Execution time for whole script = `utility/timer.pl $sec`"
echo ""

