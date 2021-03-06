##
## https://github.com/denalitherapeutics/archs4
##
##

##BiocManager::install("denalitherapeutics/archs4")
##BiocManager::install("GEOmetadb")

library("archs4")
library(dplyr)
library(GEOmetadb)

RDIR="../../R/"
FILES="../../lib/"
PGX.DIR="../../data/"
source("../../R/pgx-init.R")
source("../../R/pgx-archs4.R")
source("../../R/ngs-functions.R")
source("../../R/pgx-functions.R")
source("../../R/pgx-contrasts.R")
source("../../R/pgx-upload.R")

archs4dir <- "~/.archs4data"
archs4dir <- "~/bigomics/data/archs4data"
archs4dir <- "/data/Projects/Data/archs4data"

if(0) {
    archs4_local_data_dir_create(archs4dir)
    cwd = getwd()
    cwd
    setwd(archs4dir)
    system("wget https://s3.amazonaws.com/mssm-seq-matrix/human_matrix.h5")
    system("wget https://s3.amazonaws.com/mssm-seq-matrix/human_hiseq_transcript_v2.h5")
    system("wget https://s3.amazonaws.com/mssm-seq-matrix/mouse_matrix.h5")
    system("wget https://s3.amazonaws.com/mssm-seq-matrix/mouse_hiseq_transcript_v2.h5")
    system("wget ftp://ftp.ensembl.org/pub/release-90/gtf/homo_sapiens/Homo_sapiens.GRCh38.90.gtf.gz")
    system("wget ftp://ftp.ensembl.org/pub/release-90/gtf/mus_musculus/Mus_musculus.GRCm38.90.gtf.gz")
    
    create_augmented_feature_info(datadir=archs4dir)
    archs4_local_data_dir_validate(datadir=archs4dir)
    setwd(cwd)
    cwd
}

library(archs4)
a4 <- Archs4Repository(datadir=archs4dir)

## Get titles from GEO experiments
metadb <- file.path(archs4dir,'GEOmetadb.sqlite')
if(!file.exists(metadb)) getSQLiteFile(destdir=archs4dir)
con <- dbConnect(SQLite(),metadb)
rs <- dbGetQuery(con,paste("select gse,title from gse where",
                           "contributor like '%Ivo%Kwee%'",sep=" "))
rs

rs <- dbGetQuery(con,'select gse,title from gse')
GSE.TITLE <- rs$title
names(GSE.TITLE) <- rs$gse

gse.drugs <- NULL
if(0) {
    D <- read.csv("../../lib/L1000_repurposing_drugs.txt",sep="\t",comment.char="#")
    drugs = tolower(as.character(D$pert_iname))
    drugs1 = grep("[[:punct:]]",drugs,value=TRUE,invert=TRUE)
    length(drugs1)
    drugs1 <- drugs1[nchar(drugs1)>=8]
    length(drugs1)
    ##ok1 <- grepl(paste(drugs1[1:20],collapse="|"),tolower(GSE.TITLE))    
    ok1 <- grepl(paste(drugs1[1:2000],collapse="|"),tolower(GSE.TITLE))
    ok2 <- grepl(paste(drugs1[2001:length(drugs1)],collapse="|"),tolower(GSE.TITLE))
    about.drugs <- (ok1 | ok2)
    table(about.drugs)

    gse.drugs <- names(GSE.TITLE)[which(about.drugs)]
    head(GSE.TITLE[gse.drugs])
    tail(GSE.TITLE[gse.drugs])
}

##================================================================================
##================================= FUNCTIONS ====================================
##================================================================================

ext="-immune";outdir="gse"
ext="test";outdir="test"
id="GSE100425"
id="GSE105087"
id="GSE107655"

prepArchs4Dataset <- function(id, ext="", outdir=NULL) {
    
    pgx.file <- file.path(archs4dir,paste0(id,ext,".pgx"))
    if(!is.null(outdir)) {
        dir <- file.path(archs4dir,outdir)
        dir.exists(dir)
        if(!dir.exists(dir)) system(paste("mkdir -p",dir))
        pgx.file <- file.path(archs4dir,outdir,paste0(id,ext,".pgx"))
        pgx.file
    }
    pgx.file
    if(file.exists(pgx.file)) {
        cat("skipping already done GEO series",id,"...\n")
        return("already done")
    }

    cat("retrieving Archs4 data for GEO series",id,":",GSE.TITLE[id],"\n")
    aa <- NULL
    try.error <- try( aa <- pgx.getArchs4Dataset(a4, id) )

    if(class(try.error)=="try-error" || is.null(aa)) {
        cat("skipping. get dataset failed\n")
        return("skipped. get dataset failed")
    }
    
    names(aa)
    if("group" %in% colnames(aa$samples)) {
        colnames(aa$samples) <- sub("group","xgroup",colnames(aa$samples))
    }
    cleanupSpaces <- function(s) gsub("[ ]+"," ",gsub("^[ ]+|[ ]+$","",s))
    aa$samples <- apply(aa$samples,2,cleanupSpaces)
    aa$samples <- data.frame(aa$samples, stringsAsFactors=FALSE)
    aa$samples$batch <- NULL  ## no batch correction for the moment...
    
    ## get categorical phenotypes
    df <- aa$samples
    vv <- pgx.getCategoricalPhenotypes(df, max.ncat=10, min.ncat=2) 
    vv
    if(length(vv)==0) {
        cat("skipping. no valid phenotypes in GEO series",id,"...\n")
        return("skipped. no valid phenotypes")
    }
    cat("found discrete phenotypes:",vv,"\n")
    df <- df[,vv,drop=FALSE]
    apply(df,2,table)
    
    ## create contrast matrix
    mingrp=3;slen=15;ref=NA
    res <- pgx.makeAutoContrast(df, mingrp=3, slen=15, ref=NA)
    is.null(res)
    table(res$group)
    
    if(is.null(res)) {
        cat("skipping. no valid contrasts...\n")
        return("skipped. no valid contrasts")
    }
    
    names(res)
    head(res$contr.matrix)
    aa$samples <- cbind(aa$samples, group=res$group)
    aa$contrasts <- res$contr.matrix
    head(aa$contrasts)
    
    dim(aa$genes)
    dim(aa$counts)
    dim(aa$samples)
    dim(aa$contrasts)

    has.contrast <- (!is.null(aa$contrasts) && ncol(aa$contrasts)>0)
    has.contrast    
    if(!has.contrast) {
        return("skipped. no valid contrasts")
    } else {
    
        ## Playground pre-computation
        counts=aa$counts;samples=aa$samples;contrasts=aa$contrasts
        ngs <- pgx.upload(
            aa$counts, aa$samples, aa$contrasts,
            max.genes = 5000,
            gx.methods = c("trend.limma","edger.qlf","edger.lrt"),
            gset.methods = c("fisher","gsva","fgsea"),
            ##extra.methods = c("meta.go","deconv","infer","drugs","wordcloud"),
            extra.methods = c("meta.go","infer","drugs","wordcloud"),
            lib.dir = "../../lib",
            only.hugo = TRUE,
            progress=NULL)
        
        names(ngs)
        
        ## save
        ngs$name <- id
        ngs$description <- paste0(id,". ",GSE.TITLE[id],".")
        ngs$datatype <- "RNA-seq"
        ngs$organism <- ngs.detectOrganism(ngs)
        ngs$date <- Sys.Date()
        ngs$link <- paste0("https://www.ncbi.nlm.nih.gov/geo/query/acc.cgi?acc=",id)
        
        cat("object size: ",format(object.size(ngs), units="MB"),"\n")
        cat(">>> saving PGX file ",pgx.file,"\n")
        ngs.save(ngs, file=pgx.file)
        return("OK")
    }    

}


##================================================================================
##================================= MAIN =========================================
##================================================================================

## all series ID
samplesize <- table(a4$sample_table$series_id)
all_ids = names(samplesize[ samplesize>=20 & samplesize<=200 ])
all_ids = names(samplesize[ samplesize>=10 & samplesize<=500 ])
all.titles <- tolower(GSE.TITLE[all_ids])
length(all_ids)
table(all_ids %in% names(GSE.TITLE))

## Select studies with relevant terms
ids.list <- list()
ids.list[["aging"]] <- all_ids[grep("[ ]aging|^aging|senesc",all.titles)]
ids.list[["immune"]] <- all_ids[grep("immun",all.titles)]
ids.list[["prostate"]] <- all_ids[grep("prostate.cancer",all.titles)]
ids.list[["breast"]] <- all_ids[grep("breast.cancer",all.titles)]
ids.list[["bloodcancers"]] <- all_ids[grep("lymphom|leukaem|hemato",all.titles)]
##ids.list[["cancer"]] <- all_ids[grep("cancer|onco|tumor|tumour",all.titles)]
if(!is.null(gse.drugs)) ids.list[["drugs"]] <- intersect(all_ids, gse.drugs)

sapply(ids.list, length)
id = ids.list[[1]][1]
id

require(parallel)
i=1
for(i in 1:length(ids.list)) {
    ext <- paste0("-",names(ids.list)[i])
    ids <- ids.list[[i]]
    outdir <- paste0("gse",ext)
    outdir
    
    ##NUMCORES = 8
    NUMCORES = 1
    if(NUMCORES>1) {
        res <- mclapply(ids[], function(id)
            prepArchs4Dataset(id, ext=ext, outdir=outdir),
            mc.cores = NUMCORES)
        unlist(res)
    } else {
        j=1
        res <- rep("",length(ids))
        names(res) <- ids
        for(j in 1:length(ids)) {
            id <- ids[j]
            id
            res[j] <- prepArchs4Dataset(id, ext=ext, outdir=outdir)
        }
    }
}

res


if(0) {
    id="GSE101868"
    id = "GSE101766"
    i=1;j=1
    ext <- paste0("-",names(ids.list)[i])
    ids <- ids.list[[i]]
    id = ids[j]
    id
    prepArchs4Dataset(id, ext="test", outdir="test")
}
