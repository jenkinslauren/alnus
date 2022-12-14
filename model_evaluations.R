# model evaluations
# author: Lauren Jenkins
# 12 April 2022
# last updated: 6 July 2022

rm(list = ls())

library(xlsx)

library(enmSdm)
library(geosphere)
library(sp)
library(dismo)
library(rgeos)

cluster <- T

if (cluster == T) { # constants for running on cluster
  args <- commandArgs(TRUE)
  
  evalType <- args[1]
  evalType <- as.character(evalType)
  
  gcmList <- args[2]
  gcmList <- unlist(gcmList)
  
  genus <- args[3]
  genus <- as.character(genus)
  
  speciesList <- args[4]
  speciesList <- strsplit(speciesList, split = ', ')
  speciesList <- unlist(speciesList)
  
  baseFolder <- '/mnt/research/TIMBER/PVMvsENM/'
  setwd(paste0(baseFolder, genus, '/in/'))
  
} else {
  evalType <- 'geo'
  
  ## genus constants ##
  genus <- 'alnus'
  speciesList <- paste0('Alnus ', 
                        c('serrulata'))
  
  gcmList <- c('hadley', 'ccsm', 'ecbilt') # general circulation models for env data
  
  baseFolder <- '/Volumes/lj_mac_22/MOBOT/by_genus/'
  setwd(paste0(baseFolder, genus))
}

ll <- c('longitude', 'latitude')
pc <- 5
predictors <- c(paste0('pca', 1:pc))

for (gcm in gcmList) {
  print(paste0("GCM = ", gcm))
  
  a <- data.frame(c(seq(1:5)))
  c <- data.frame(c(seq(1:5)))
  colnames(a)[1] <- colnames(c)[1] <- 'fold #'
  
  for(sp in speciesList) {
    print(paste0("Species = ", sp))
    
    speciesAb_ <- sub("(.{4})(.*)", "\\1_\\2", 
                      paste0(substr(sp,1,4), toupper(substr(sub("^\\S+\\s+", '', sp),1,1)), 
                             substr(sub("^\\S+\\s+", '', sp),2,4)))
    
    # set constants for retrieving background sites #
    bgFileName <- paste0(baseFolder, 
                         'background_sites/Random Background Sites across Study Region.Rdata')
    load(bgFileName) # load bg sites in calibration region
    
    # set constants for retrieving model objects #
    modelFileName <- paste0('./models/predictions/', speciesAb_, 
                            '/GCM_', gcm, '_PC', pc, '.rData')
    load(modelFileName) # load model object, bg, and records for given species
    
    evalFolderName <- paste0('/mnt/home/f0103321/', genus, '/model_evaluations/', 
                             evalType, '_k_folds/')
    if(!dir.exists(evalFolderName)) dir.create(evalFolderName, recursive = TRUE, 
                                               showWarnings = FALSE)
    
    evalFolderName <- paste0(evalFolderName, speciesAb_, '/')
    if(!dir.exists(evalFolderName)) dir.create(evalFolderName, recursive = TRUE, 
                                               showWarnings = FALSE)
    
    evalFolderName <- paste0(evalFolderName, gcm, '/')
    if(!dir.exists(evalFolderName)) dir.create(evalFolderName, recursive = TRUE, 
                                               showWarnings = FALSE)
    
    # variable to store auc & cbi output
    auc <- cbi <- rep(NA, 5)
    
    if (evalType == 'random') {
      kPres <- kfold(records, k = 5) # k-folds for presences
      kBg <- kfold(bg, k = 5) # k-folds for backgrounds
      
      ### code for visualizing folds ###
      # plot(range, main = paste0(sp, ', k-fold #1'))
      # points(records$longitude, records$latitude)
      # points(records$longitude[kPres==1],
      #        records$latitude[kPres==1],
      #        bg='red',
      #        pch=21
      # )
      
      # legend('topright',
      #        legend=c('Training presence', 'Test presence'),
      #        pch=c(1, 16),
      #        col=c('black', 'red'),
      #        bg='white',
      #        cex=0.8
      # )
      
      for(j in 1:5) { # for each k-fold
        print(paste0('K-fold ', j, ':'))
        
        # create training data, with presences/absences vector of 0/1 with all points 
        # EXCEPT the ones in the fold
        envData <- rbind(records[kPres != j, predictors], bg[kBg != j, predictors])
        presBg <- c(rep(1, sum(kPres != j)), rep(0, sum(kBg != j)))
        trainData <- cbind(presBg, envData)
        
        eval_model_tune <- enmSdm::trainMaxNet(data = trainData, resp = 'presBg', 
                                               classes = 'lpq', out = c('models', 'tuning'))
        eval_model <- eval_model_tune$models[[1]]
        
        # predict presences & background sites
        predPres <- raster::predict(eval_model, 
                                    newdata = records[kPres == j,],
                                    clamp = F,
                                    type = 'cloglog')
        predBg <- raster::predict(eval_model, 
                                  newdata = bg[kPres == j,],
                                  clamp = F,
                                  type = 'cloglog')
        
        evalFileName <- paste0(evalFolderName, 'model_', j, '.Rdata')
        
        save(eval_model, eval_model_tune, predPres, predBg, kPres, kBg, eval_model_tune,
             file = evalFileName,
             overwrite = T)
        
        # evaluate
        thisEval <- evaluate(p = as.vector(predPres), a = as.vector(predBg))
        thisAuc <- thisEval@auc
        thisCbi <- contBoyce(pres = predPres, bg = predBg)
        
        # print(paste('AUC = ', round(thisAuc, 2), ' | CBI = ', round(thisCbi, 2)))
        
        auc[j] <- thisAuc
        cbi[j] <- thisCbi
        
        # save.image(paste0('./models/model_evaluations/workspaces/', evalType, '/', 
        #            gcm, '/', speciesAb_, '_model_', j))
      }
    } else if (evalType == 'geo') {
      # create g-folds
      gPres <- geoFold(x = records, k = 5, minIn = 5, minOut = 10, longLat = ll)
      
      # now, we have our folds, but we want to divide the bg sites into 
      # folds based on where they are in relation to records
      
      # initialize vectors to store g-fold assignments
      gTestBg <- rep(NA, nrow(bg))
      
      # convert records to sp object for gDistance function
      sp.records <- records
      coordinates(sp.records) <- ~longitude + latitude
      sp.randomBg <- bg
      coordinates(sp.randomBg) <- ~longitude + latitude
      
      # divide bg sites between training & test
      nearest <- apply(gDistance(sp.records, sp.randomBg, byid = T), 1, which.min)
      
      for (j in 1:nrow(bg)) {
        gTestBg[j] <- gPres[nearest[j]]
      }
      
      for (m in 1:5) { # make training data frame with predictors 
        # and vector of 1/0 for presence/background
        print(paste0('G-fold ', m, ':'))
        
        envData <- rbind(
          records[gPres!=m, predictors],
          bg[gTestBg!=m, predictors]
        )
        
        presBg <- c(rep(1, sum(gPres!=m)), rep(0, sum(gTestBg!=m)))
        trainData <- cbind(presBg, envData)
        
        # maxent model
        eval_model_tune <- enmSdm::trainMaxNet(data = trainData, resp = 'presBg', 
                                               classes = 'lpq', out = c('models', 'tuning'))
        eval_model <- eval_model_tune$models[[1]]
        
        # predict presences & background sites
        predPres <- raster::predict(eval_model, 
                                    newdata = records[gPres == m,],
                                    clamp = F,
                                    type = 'cloglog')
        predBg <- raster::predict(eval_model, 
                                  newdata = bg[gTestBg == m,],
                                  clamp = F,
                                  type = 'cloglog')
        
        evalFileName <- paste0(evalFolderName, 'model_', m, '.Rdata')
        
        save(eval_model, predPres, predBg, gPres, gTestBg, eval_model_tune,
             file = evalFileName,
             overwrite = T)
        
        # evaluate
        thisEval <- evaluate(p = as.vector(predPres), a = as.vector(predBg))
        thisAuc <- thisEval@auc
        thisCbi <- contBoyce(pres = predPres, bg = predBg)
        
        # print(paste('AUC = ', round(thisAuc, 2), ' | CBI = ', round(thisCbi, 2)))
        
        auc[m] <- thisAuc
        cbi[m] <- thisCbi
        
        # save.image(paste0('./models/model_evaluations/workspaces/', evalType, '/', 
        #            gcm, '/', speciesAb_, '_model_', m))
        
      }
    }
    a <- cbind(a, auc)
    c <- cbind(c, cbi)
    n <- ncol(a)
    colnames(a)[n] <- colnames(c)[n] <- sp
  }
  
  
  write.xlsx(a, file = paste0('./models/model_evaluations/', evalType, '_evals.xlsx'), 
             sheetName = paste0(gcm, '_auc'), append = T, row.names = F)
  write.xlsx(c, file = paste0('./models/model_evaluations/', evalType, '_evals.xlsx'), 
             sheetName = paste0(gcm, '_cbi'), append = T, row.names = F)
  
  save(a, c, file = paste0('./models/model_evaluations/', gcm, '_evals.Rdata'))
}

### save AUC and CBI to Excel sheet ###

evalTypes <- c('geo', 'random')

## genus constants ##
genus <- 'alnus'
speciesList <- paste0('Alnus ', 
                      c('serrulata'))

gcmList <- c('hadley', 'ccsm', 'ecbilt') # general circulation models for env data

baseFolder <- '/Volumes/lj_mac_22/MOBOT/by_genus/'
setwd(paste0(baseFolder, genus))
for (evalType in evalTypes) {
  for (gcm in gcmList) {
    print(paste0("GCM = ", gcm))
    
    a <- data.frame(c(seq(1:5)))
    c <- data.frame(c(seq(1:5)))
    colnames(a)[1] <- colnames(c)[1] <- 'fold #'
    
    for (sp in speciesList) {
      speciesAb_ <- sub("(.{4})(.*)", "\\1_\\2", 
                        paste0(substr(sp,1,4), toupper(substr(sub("^\\S+\\s+", '', sp),1,1)), 
                               substr(sub("^\\S+\\s+", '', sp),2,4)))
      
      evalFolderName <- paste0(baseFolder, genus, '/models/model_evaluations/', 
                               evalType, '_k_folds/', speciesAb_, '/', gcm, '/')
      
      # variable to store auc & cbi output
      auc <- cbi <- rep(NA, 5)
      
      for (m in 1:5) {
        evalFileName <- paste0(evalFolderName, 'model_', m, '.Rdata')
        
        load(evalFileName)
        
        # evaluate
        thisEval <- evaluate(p = as.vector(predPres), a = as.vector(predBg))
        thisAuc <- thisEval@auc
        thisCbi <- contBoyce(pres = predPres, bg = predBg)
        
        # print(paste('AUC = ', round(thisAuc, 2), ' | CBI = ', round(thisCbi, 2)))
        
        auc[m] <- thisAuc
        cbi[m] <- thisCbi
      }
      a <- cbind(a, auc)
      c <- cbind(c, cbi)
      n <- ncol(a)
      colnames(a)[n] <- colnames(c)[n] <- sp
    }
    
    write.xlsx(a, file = paste0('./models/model_evaluations/', evalType, '_evals.xlsx'), 
               sheetName = paste0(gcm, '_auc'), append = T, row.names = F)
    write.xlsx(c, file = paste0('./models/model_evaluations/', evalType, '_evals.xlsx'), 
               sheetName = paste0(gcm, '_cbi'), append = T, row.names = F)
    
    save(a, c, file = paste0('./models/model_evaluations/', gcm, '_evals.Rdata'))
  }
}
