#!/bin/bash

for FILE in $(find . -type f -name "*.nim");
do
 if [[ -f ${FILE%.nim} ]]; then
   echo binary ${FILE%.nim}, found for $FILE
   rm ${FILE%.nim}
 fi
done
