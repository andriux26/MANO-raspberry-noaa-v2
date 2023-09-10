#! /bin/bash

A=$(echo $5 | cut -c29-44)
B=$(echo $5 | cut -c45-60)
echo  $B$A 
